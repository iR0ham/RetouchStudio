"""The provenance sidecar an adopted artifact carries (W5-0 §3.6).

The contract is frozen: every artifact the app adopts has a `*.provenance.json`
beside it, and a job that does not adopt writes none.

Publication is ordered, not atomic. Two renames are two system calls and no
filesystem makes them one, so the design picks the direction the failure can
go in: the sidecar lands first and the artifact rename is the commit point.
Either the pair is complete, or the artifact never appeared. A crash between
the two renames leaves a sidecar with nothing beside it, which is inert — a
reader needs the artifact to adopt anything — and `reconcile` removes such an
orphan from a job folder. The reverse state, an artifact without provenance,
is the one this module refuses to create.

Every value here is measured, never assumed. The digests and pixel geometry
come from the bytes the job wrote, the model identity comes from what the
loader actually resolved, and the provider is the device the inference ran on.
The artifact's entry is measured on the staged file: the rename that publishes
it moves those exact bytes, so the recorded digest is the digest of the
published file, and `publish` re-reads both after the commit to prove the
pair agrees. A legacy flat install has no version of its own, so
`model.version` stays null instead of borrowing the catalog's claim.

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


class ProvenanceError(RuntimeError):
    """A provenance record that cannot be trusted for the file beside it."""


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
    """Write `<artifact>.provenance.json` beside the artifact and return it.

    The bytes are serialised before anything is created, so a record that
    cannot be written leaves the folder untouched. A temp that was opened but
    not renamed is removed on the way out, and only that temp: a file this
    call never created is never deleted.
    """
    payload = json.dumps(record, ensure_ascii=False, separators=(",", ":"),
                         sort_keys=True).encode("utf-8")
    folder = artifact_path.parent
    temp = folder / f".{artifact_path.name}{SIDECAR_SUFFIX}.{uuid.uuid4()}.tmp"
    sidecar = sidecar_path(artifact_path)
    created = False
    try:
        fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW
                     | os.O_CLOEXEC, 0o600)
        created = True
        try:
            offset = 0
            while offset < len(payload):
                offset += os.write(fd, payload[offset:])
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temp, sidecar)
    except BaseException:
        if created:
            temp.unlink(missing_ok=True)
        raise
    return sidecar


def read(sidecar: Path) -> dict:
    """Parse a sidecar, refusing anything that is not this schema."""
    try:
        document = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ProvenanceError(
            f"the provenance sidecar cannot be read: {exc}") from exc
    if not isinstance(document, dict) or document.get("schema") != SCHEMA:
        raise ProvenanceError("the provenance sidecar is not " + SCHEMA)
    return document


def verify(artifact_path: Path) -> dict:
    """The sidecar beside an artifact, checked against the artifact bytes.

    Adoption calls this: a sidecar that names a different digest is not
    evidence about the file in front of it, so it must not license the artifact.
    """
    document = read(sidecar_path(artifact_path))
    recorded = (document.get("output") or {}).get("sha256")
    actual = digest_file(artifact_path)
    if recorded != actual:
        raise ProvenanceError(
            "the provenance names a different artifact than the file beside it")
    return document


def publish(staged: Path, target: Path, record: dict) -> Path:
    """Commit a rendered artifact: the sidecar lands, then the artifact does.

    The caller has already written `staged`; nothing at `target` is visible
    until the last rename. A failed artifact rename takes the sidecar back
    with it, and a pair that disagrees after landing is removed whole, so the
    only way this returns is with a complete, self-consistent artifact.
    """
    sidecar = write(target, record)
    try:
        os.replace(staged, target)
    except BaseException:
        sidecar.unlink(missing_ok=True)
        raise
    try:
        verify(target)
    except BaseException:
        target.unlink(missing_ok=True)
        sidecar.unlink(missing_ok=True)
        raise
    return sidecar


def reconcile(folder: Path) -> list[Path]:
    """Remove sidecars in a job folder that have no artifact beside them.

    This is the crash recovery for the window between the two renames. It
    touches files ending in `.provenance.json` directly inside `folder` and
    only those whose artifact is absent, so a completed pair, the artifacts
    themselves and any other file are left exactly as they were.
    """
    orphans = []
    for entry in sorted(folder.glob("*" + SIDECAR_SUFFIX)):
        name = entry.name[: -len(SIDECAR_SUFFIX)]
        if not name or (folder / name).exists():
            continue
        entry.unlink(missing_ok=True)
        orphans.append(entry)
    return orphans
