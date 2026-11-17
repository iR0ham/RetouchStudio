"""Model catalog: what the worker may load, and under which license.

The catalog is data, not comments. Every entry carries an SPDX license id and a
`commercial_ok` flag; the worker refuses to load anything that is not cleared
for the product unless the explicit evaluation switch is on. A model that is
missing on disk is a distinct error from one that is not licensed, so the UI can
offer "download" in one case and nothing in the other.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

from .protocol import BUSY, LICENSE_BLOCKED, MODEL_MISSING, UNKNOWN_MODEL, WorkerError

MODEL_ROOT = Path(os.environ.get(
    "RETOUCH_AI_MODELS",
    Path.home() / "Library" / "Application Support" / "RetouchStudio" / "AI" / "models",
))
_HF_FLUX = "https://huggingface.co/mflux-community/flux2-klein-4b-mflux-q4/resolve/main/"
_HF_SWIN2SR = ("https://huggingface.co/caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr/"
               "resolve/main/")


@dataclass(frozen=True)
class ModelFile:
    path: str
    sha256: str | None = None
    bytes: int | None = None
    url: str | None = None


@dataclass(frozen=True)
class ModelEntry:
    id: str
    name: str
    task: str
    license_id: str
    commercial_ok: bool
    source: str
    files: tuple[ModelFile, ...] = field(default_factory=tuple)
    notes: str = ""

    def public(self, root: Path) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "task": self.task,
            "license": self.license_id,
            "commercial_ok": self.commercial_ok,
            "installed": self.installed(root),
            "source": self.source,
            "notes": self.notes,
            "bytes": sum(f.bytes or 0 for f in self.files) or None,
        }

    def installed(self, root: Path) -> bool:
        try:
            model_root = resolve_model_root(root, self.id)
        except (OSError, ValueError):
            return False
        return all((model_root / f.path).exists() for f in self.files)


_SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# The flat layout has no version, so its lease is a distinct identity. The
# macOS and Windows stores use the same file name: `.locks/<id>@legacy`. A
# model id or version can never contain `@`, so this cannot collide with a
# versioned lock.
LEGACY_LEASE = "@legacy"


def _safe_component(value: object, field: str) -> str:
    if not isinstance(value, str) or not _SAFE_COMPONENT.fullmatch(value) or ".." in value:
        raise ValueError(f"unsafe {field}")
    return value


def resolve_model_root(root: Path, model_id: str) -> Path:
    """Active version directory, or the legacy flat folder when no pointer exists.

    Legacy flat folders predate the versioned store; reading them keeps an
    already-installed model usable. Once `active.json` exists it is the only
    answer: a dangling pointer is an error, never a silent fallback.
    """
    _safe_component(model_id, "model id")
    model_root = root / model_id
    pointer = model_root / "active.json"
    if not pointer.is_file():
        return model_root
    data = json.loads(pointer.read_text(encoding="utf-8"))
    if data.get("schema") != "retouchstudio.model-active/1" or data.get("modelId") != model_id:
        raise ValueError("active pointer identity mismatch")
    version = _safe_component(data.get("version"), "model version")
    target = model_root / version
    if not target.is_dir():
        raise FileNotFoundError(f"active version {version} is missing")
    return target


CATALOG: tuple[ModelEntry, ...] = (
    ModelEntry(
        id="flux2-klein-4b-q4",
        name="FLUX.2 klein 4B (q4)",
        task="generative-edit",
        license_id="Apache-2.0",
        commercial_ok=True,
        source="hf:mflux-community/flux2-klein-4b-mflux-q4",
        files=(
            ModelFile("text_encoder/0.safetensors",
                      "e59ed2b6825cb8ae3d0ba1e8a43575a565d465ce4518b7d79d28020b19b639cd", 2_135_435_237,
                      _HF_FLUX + "text_encoder/0.safetensors"),
            ModelFile("text_encoder/1.safetensors",
                      "edbdea3187bc4a0ad0e1ecb7152da8e6b344669413d9e45be5e7a2244f398ee3", 127_582_075,
                      _HF_FLUX + "text_encoder/1.safetensors"),
            ModelFile("transformer/0.safetensors",
                      "36796395e3946496f3e118f26fe22594b1d7d871342a59dd7824349d91c08266", 2_145_323_769,
                      _HF_FLUX + "transformer/0.safetensors"),
            ModelFile("transformer/1.safetensors",
                      "9730ae148ca4f5ffc62860748b849a70987f0b7301588248bd98a2af9bc15070", 34_727_728,
                      _HF_FLUX + "transformer/1.safetensors"),
            ModelFile("vae/0.safetensors",
                      "688ae0c3d2e93573ce8a6d3561d793cf6de5a4207b2e128cad6cd0d71e43b10f", 165_107_888,
                      _HF_FLUX + "vae/0.safetensors"),
        ),
        notes="Distilled; 4 steps, guidance 1.0. KV cache rejected on M3 (16.7 GB peak).",
    ),
    ModelEntry(
        id="sam2.1-hiera-tiny",
        name="SAM 2.1 tiny",
        task="segmentation",
        license_id="Apache-2.0",
        commercial_ok=True,
        source="hf:facebook/sam2.1-hiera-tiny",
        files=(ModelFile("sam2.1_hiera_tiny.pt", url=
                         "https://dl.fbaipublicfiles.com/segment_anything_2/092824/"
                         "sam2.1_hiera_tiny.pt"),),
        notes="Point/box prompts; 21 ms warm at 1024².",
    ),
    ModelEntry(
        id="swin2sr-x4",
        name="Swin2SR x4 (real-world)",
        task="upscaling",
        license_id="Apache-2.0",
        commercial_ok=True,
        source="hf:caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr",
        files=(
            ModelFile("config.json",
                      "1e986fb6d0b6de32bae01a6ccd756e5d8ae1525dcb52f7ee5b2dc7f6132d6365", 772,
                      _HF_SWIN2SR + "config.json"),
            ModelFile("preprocessor_config.json",
                      "cbc36266fcc93d5bc1e9ca69bcc648ae9d268918ad14cd3507216740f129cc4d", 152,
                      _HF_SWIN2SR + "preprocessor_config.json"),
            ModelFile("pytorch_model.bin",
                      "4a5f52a20932085557ed115f87c0ee8385e12f2719108c0dfd38c64aedea4710", 48_460_141,
                      _HF_SWIN2SR + "pytorch_model.bin"),
        ),
        notes="Apache-2.0 model card (weights included). 12.05 M params; "
              "6.2 s per 256² tile on MPS (measured, M3 16 GB).",
    ),
    ModelEntry(
        id="migan",
        name="MI-GAN (512, Places2)",
        task="inpainting",
        license_id="MIT",
        commercial_ok=True,
        source="hf:andraniksargsyan/migan",
        files=(ModelFile(
            "migan_pipeline_v2.onnx",
            "6f1f3530a1a2324b19752018ce756088b07973cda8d7d890034ace5c8a48c40b", 28_079_181,
            "https://huggingface.co/andraniksargsyan/migan/resolve/main/"
            "migan_pipeline_v2.onnx"),),
        notes="Weights are MIT (LICENSE-WEIGHTS); the ONNX pipeline is the "
              "author's own export. Used for small holes.",
    ),
)


class Catalog:
    def __init__(self, root: Path = MODEL_ROOT, allow_uncleared: bool | None = None) -> None:
        self.root = Path(root)
        if allow_uncleared is None:
            allow_uncleared = os.environ.get("RETOUCH_AI_EVAL_MODELS") == "1"
        self.allow_uncleared = allow_uncleared
        # Shared leases held for the process lifetime: a loaded model cannot be
        # deleted or replaced under the running job, and the kernel releases
        # them if this process dies.
        self._leases: dict[tuple[str, str], int] = {}

    def _lease(self, entry: ModelEntry, identity: str, filename: str,
               label: str) -> None:
        key = (entry.id, identity)
        if key in self._leases:
            return
        locks = self.root / ".locks"
        locks.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = locks / filename
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        deadline = time.monotonic() + 5.0
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(fd)
                    details = {"model": entry.id, "reason": "leased"}
                    if identity != LEGACY_LEASE:
                        details["version"] = identity
                    # The model is installed; another operation holds it. A
                    # busy resource the caller can retry, not a missing one.
                    raise WorkerError(
                        BUSY,
                        f"{entry.id} {label} is leased by an install or delete",
                        details,
                    )
                time.sleep(0.05)
        self._leases[key] = fd

    def _release(self, entry: ModelEntry, identity: str) -> None:
        fd = self._leases.pop((entry.id, identity), None)
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass

    def close(self) -> None:
        for fd in self._leases.values():
            try:
                os.close(fd)
            except OSError:
                pass
        self._leases.clear()

    def list(self) -> list[dict]:
        return [entry.public(self.root) for entry in CATALOG]

    def get(self, model_id: str) -> ModelEntry:
        for entry in CATALOG:
            if entry.id == model_id:
                return entry
        raise WorkerError(UNKNOWN_MODEL, f"unknown model {model_id!r}",
                          {"model": model_id})

    def require(self, model_id: str) -> Path:
        entry = self.get(model_id)
        if not entry.commercial_ok and not self.allow_uncleared:
            raise WorkerError(
                LICENSE_BLOCKED,
                f"{entry.id} is not cleared for commercial use ({entry.license_id})",
                {"model": entry.id, "license": entry.license_id},
            )
        flat_root = self.root / entry.id
        for _ in range(2):
            try:
                model_root = resolve_model_root(self.root, entry.id)
            except (OSError, ValueError) as error:
                raise WorkerError(MODEL_MISSING,
                                  f"{entry.id} has no usable active version",
                                  {"model": entry.id, "reason": str(error)})
            if model_root == flat_root:
                # Legacy flat installs share one lease with adoption, so
                # migration cannot move files under a running job. The kernel
                # releases it.
                self._lease(entry, LEGACY_LEASE, f"{entry.id}{LEGACY_LEASE}",
                            "flat installation")
            elif model_root.parent == flat_root:
                version = model_root.name
                self._lease(entry, version, f"{entry.id}-{version}", version)
            else:
                raise WorkerError(MODEL_MISSING,
                                  f"{entry.id} resolved outside its folder",
                                  {"model": entry.id})
            # Adoption holds this lease while it moves the flat files and
            # publishes the pointer, so waiting here can land on a layout the
            # lease no longer describes. Resolve again under the lease.
            try:
                fresh = resolve_model_root(self.root, entry.id)
            except (OSError, ValueError) as error:
                raise WorkerError(MODEL_MISSING,
                                  f"{entry.id} has no usable active version",
                                  {"model": entry.id, "reason": str(error)})
            if fresh == model_root:
                break
            model_root = fresh
        else:
            raise WorkerError(BUSY, f"{entry.id} kept changing layout while leasing it",
                              {"model": entry.id, "reason": "layout"})
        if model_root != flat_root:
            # The versioned lease is held; the flat one describes a layout
            # that adoption has already removed.
            self._release(entry, LEGACY_LEASE)
        for spec in entry.files:
            target = model_root / spec.path
            if not target.exists():
                raise WorkerError(MODEL_MISSING, f"{entry.id} is not installed",
                                  {"model": entry.id, "missing": spec.path,
                                   "download": entry.source})
        return model_root

    def health(self) -> dict:
        """Cheap launch check: catalog loads and every installed file is whole.

        Hashing a 4.6 GB model would make launch wait minutes, so this compares
        the recorded size instead. `models verify` remains the deep check, and
        a model that is simply not installed is reported but is not a failure.
        """
        models, ok = [], True
        for entry in CATALOG:
            installed = entry.installed(self.root)
            state = {"model": entry.id, "installed": installed, "ok": True}
            if installed:
                model_root = resolve_model_root(self.root, entry.id)
                for spec in entry.files:
                    target = model_root / spec.path
                    if spec.bytes is not None and target.stat().st_size != spec.bytes:
                        state["ok"] = False
                        state.setdefault("problems", []).append(
                            {"file": spec.path, "reason": "size"})
                ok = ok and state["ok"]
            models.append(state)
        return {"ok": ok, "root": str(self.root), "models": models}

    def verify(self, model_id: str) -> dict:
        entry = self.get(model_id)
        try:
            model_root = resolve_model_root(self.root, entry.id)
        except (OSError, ValueError) as error:
            raise WorkerError(MODEL_MISSING, f"{entry.id} has no usable active version",
                              {"model": entry.id, "reason": str(error)})
        checked, failed = 0, []
        for spec in entry.files:
            if spec.sha256 is None:
                continue
            target = model_root / spec.path
            if not target.exists():
                failed.append({"file": spec.path, "reason": "missing"})
                continue
            digest = hashlib.sha256()
            with target.open("rb") as handle:
                for block in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(block)
            if digest.hexdigest() != spec.sha256:
                failed.append({"file": spec.path, "reason": "checksum"})
            checked += 1
        return {"model": entry.id, "checked": checked, "failed": failed,
                "ok": not failed}
