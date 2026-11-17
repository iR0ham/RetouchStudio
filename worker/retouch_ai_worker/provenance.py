"""The provenance sidecar an adopted artifact carries (W5-0 §3.6).

The contract is frozen: every artifact the app adopts has a `*.provenance.json`
beside it, and a job that does not adopt writes none. The worker therefore writes
the sidecar only after the artifact is published, atomically, and a cancelled job
leaves neither file behind.

Every value here is measured, never assumed. The digests and pixel geometry come
from the bytes on disk after the job wrote them, the model identity comes from
what the loader actually resolved, and the provider is the device the inference
ran on. A legacy flat install has no version of its own, so `model.version`
stays null instead of borrowing the catalog's claim.

The one field this module cannot measure is the colour space of the *input*: a
job receives decoded pixels (shared memory or a data URL is as valid as a path),
and the decode does not preserve a source profile. The input digest therefore
covers the pixels the job used, and `colorSpace` is reported only for the output
file, where the bytes can be inspected.
"""
from __future__ import annotations

import hashlib
import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "retouchstudio.ai.provenance/1"
SIDECAR_SUFFIX = ".provenance.json"

# Channels per mode for the images the adapters write. A mode outside this
# table is reported with one channel rather than guessed at.
_CHANNELS = {"L": 1, "LA": 2, "P": 1, "RGB": 3, "RGBA": 4, "CMYK": 4}


def digest_file(path: Path) -> str:
    """SHA-256 of a file, read in blocks so a large artifact stays cheap."""
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(block)
    return hasher.hexdigest()


def geometry(array) -> dict:
    """The `{width, height, bitDepth, channels}` a decoded pixel buffer has."""
    return {"width": int(array.shape[1]), "height": int(array.shape[0]),
            "bitDepth": 8 * array.dtype.itemsize,
            "channels": int(array.shape[2]) if array.ndim > 2 else 1}


def measure(path: Path) -> dict:
    """Width, height, bit depth and colour space as the artifact itself says.

    The file is reopened rather than trusting the array that produced it: a
    writer that silently round-tripped to 8 bits must be recorded as 8 bits.
    """
    from PIL import Image

    with Image.open(path) as image:
        mode = image.mode
        channels = _CHANNELS.get(mode, 1)
        depth = 16 if "I;16" in mode or mode == "I" else 8
        return {"width": image.width, "height": image.height, "bitDepth": depth,
                "channels": channels,
                "colorSpace": "embedded-profile"
                if image.info.get("icc_profile") else "untagged"}


def artifact(path: Path) -> dict:
    """A complete `output` entry: the digest and geometry of the file bytes."""
    return {"sha256": digest_file(path), **measure(path)}


def pixels(array) -> dict:
    """A complete `input` entry for the pixel buffer a job was handed."""
    return {"sha256": hashlib.sha256(array.tobytes()).hexdigest(),
            **geometry(array)}


def document(*, capability_id: str, job_id: str, contract_version: str,
             model: dict, adapter: dict, parameters: dict, seed: int | None,
             input: dict, output: dict, authorized_rect: dict,
             outside_pixels_identical: bool | None, elapsed_seconds: float,
             state: str) -> dict:
    """The §3.6 field set, in the order the decision record lists it."""
    return {
        "schema": SCHEMA,
        "contractVersion": contract_version,
        "capabilityId": capability_id,
        "jobId": job_id,
        "createdAt": datetime.now(timezone.utc).isoformat(
            timespec="seconds").replace("+00:00", "Z"),
        "model": model,
        "adapter": adapter,
        "parameters": parameters,
        "seed": seed,
        "input": input,
        "output": output,
        "authorizedRect": authorized_rect,
        "outsidePixelsIdentical": outside_pixels_identical,
        "elapsedSeconds": elapsed_seconds,
        "state": state,
    }


def sidecar_path(artifact_path: Path) -> Path:
    return artifact_path.with_name(artifact_path.name + SIDECAR_SUFFIX)


def write(artifact_path: Path, record: dict) -> Path:
    """Write `<artifact>.provenance.json` beside the artifact and return it."""
    payload = json.dumps(record, ensure_ascii=False, separators=(",", ":"),
                         sort_keys=True).encode("utf-8")
    folder = artifact_path.parent
    temp = folder / f".{artifact_path.name}{SIDECAR_SUFFIX}.{uuid.uuid4()}.tmp"
    fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW
                 | os.O_CLOEXEC, 0o600)
    try:
        offset = 0
        while offset < len(payload):
            offset += os.write(fd, payload[offset:])
        os.fsync(fd)
        os.replace(temp, sidecar_path(artifact_path))
    except BaseException:
        temp.unlink(missing_ok=True)
        raise
    finally:
        os.close(fd)
    return sidecar_path(artifact_path)
