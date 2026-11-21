"""Model catalog: what the worker may load, and under which license.

The catalog is data, not comments. Every entry carries an SPDX license id and a
`commercial_ok` flag; the worker refuses to load anything that is not cleared
for the product unless the explicit evaluation switch is on. A model that is
missing on disk is a distinct error from one that is not licensed, so the UI can
offer "download" in one case and nothing in the other.

Integrity is fail-closed at three layers, and each has its own reason string:

* **Admission.** An entry whose pin is absent or malformed cannot be loaded,
  reported healthy or bound to a capability. A missing size, a missing SHA-256
  or a digest that is not 64 hex characters is a defect in the catalog, so it is
  refused before any byte of the model is read (`pin_problem`).
* **Load.** `require_verified` checks the recorded size and then hashes every
  file, and it is the only accessor a job path may use. `require` is size-only
  and is documented as a no-bytes-read accessor for reporting.
* **Cache.** The digest proof is memoised per artifact identity plus the
  catalog's generation, so a process pays for hashing once instead of once per
  poll; publishing a new version, repairing bytes in place or editing the
  catalog invalidates it (see `_proofs`).
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

from .protocol import (BUSY, CHECKSUM_MISMATCH, CATALOG_INVALID, LICENSE_BLOCKED,
                       MODEL_MISSING, UNKNOWN_MODEL, WorkerError)

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

# A SHA-256 pin is 64 hex characters. Upper-case hex is a valid digest written
# in another case, so it is normalised rather than rejected; anything else
# (empty, truncated, non-hex) can never equal `hexdigest()` and is a catalog
# defect, not a damaged model.
_SHA256_HEX = re.compile(r"^[0-9a-fA-F]{64}$")

# The flat layout has no version, so its lease is a distinct identity. The
# macOS and Windows stores use the same file name: `.locks/<id>@legacy`. A
# model id or version can never contain `@`, so this cannot collide with a
# versioned lock.
LEGACY_LEASE = "@legacy"

# Reasons a load may be refused for integrity reasons. They travel in
# `WorkerError.data["reason"]` so the host can tell a user *which* side is wrong
# without parsing a message: `missing-size`, `missing-digest` and
# `invalid-digest` mean the catalog entry itself is unusable, `unreadable` means
# the file could not be opened, `size` and `digest` mean real bytes disagreed
# with the record.
REASON_MISSING_SIZE = "missing-size"
REASON_MISSING_DIGEST = "missing-digest"
REASON_INVALID_DIGEST = "invalid-digest"
REASON_INCOMPLETE_ENTRY = "incomplete-entry"
REASON_UNSAFE_PATH = "unsafe-path"
REASON_SIZE = "size"
REASON_DIGEST = "digest"
REASON_UNREADABLE = "unreadable"

# `pin_problem` reports the first defect it finds, in this order, so a message
# can name the class without re-deriving it.
PIN_REASONS = (REASON_MISSING_DIGEST, REASON_INVALID_DIGEST, REASON_MISSING_SIZE,
               REASON_INCOMPLETE_ENTRY, REASON_UNSAFE_PATH)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _pins_of(entry: ModelEntry) -> tuple:
    """The entry's whole pin set, normalised, for catalog-identity hashing."""
    return (entry.id, entry.commercial_ok, entry.license_id,
            tuple((spec.path, normalize_digest(spec.sha256), spec.bytes)
                  for spec in entry.files))


def normalize_digest(value: object) -> str | None:
    """The lower-case hex form of a recorded digest, or None when malformed."""
    if not isinstance(value, str) or not _SHA256_HEX.fullmatch(value):
        return None
    return value.lower()


def pin_problem(entry: ModelEntry) -> tuple[str, str, str] | None:
    """Why this catalog entry cannot be verified, or None when it can.

    Checked per file, in catalog order, so the answer names the first defect.
    An entry with no files at all is incomplete: there is nothing to load, and
    treating that as a healthy empty install would be a silent pass.

    This is the single admission rule. `require`, `require_verified`, `health`,
    `verify`, `capability.list` and the download plan all ask it, which is what
    keeps the reporting layer from calling an entry usable while the load layer
    refuses it — the disagreement the audit measured.
    """
    if not entry.files:
        return (REASON_INCOMPLETE_ENTRY, "",
                f"{entry.id} has no files recorded in the catalog")
    for spec in entry.files:
        digest = normalize_digest(spec.sha256)
        if digest is None:
            if spec.sha256 is None or spec.sha256 == "":
                return (REASON_MISSING_DIGEST, spec.path,
                        f"{entry.id} {spec.path} has no recorded SHA-256, so its "
                        "bytes cannot be verified")
            return (REASON_INVALID_DIGEST, spec.path,
                    f"{entry.id} {spec.path} has a malformed SHA-256 in the "
                    f"catalog ({spec.sha256!r} is not 64 hexadecimal characters)")
        if spec.bytes is None:
            return (REASON_MISSING_SIZE, spec.path,
                    f"{entry.id} {spec.path} has no recorded exact size")
    # Mandate §4 case 6, the half a null pin used to hide: a listed path that
    # leaves the model folder, or cannot be named safely at all, would make every
    # integrity check below run on some *other* file than the one the runtime
    # later opens. `resolve_model_root` guards the id and the version; nothing
    # guarded the per-file paths, so `../../etc/passwd` was a legal pin.
    for spec in entry.files:
        if not _safe_relative_path(spec.path):
            return (REASON_UNSAFE_PATH, spec.path,
                    f"{entry.id} records an unsafe file path {spec.path!r}, so its "
                    "pins cannot be bound to the bytes a loader opens")
    return None


def _safe_relative_path(value: object) -> bool:
    """True when a catalog file path stays inside the model folder it pins.

    A path may nest (`vae/0.safetensors` is legitimate), but it must be relative,
    free of `..`, made only of safe components and not a symlink. This is the
    check `_safe_component` cannot express for a multi-part path, and it runs on
    the *recorded* string — before any pin is compared to a file.
    """
    if not isinstance(value, str) or not value or value.startswith("/"):
        return False
    if "\\" in value or "\x00" in value:
        return False
    parts = value.split("/")
    if any(not part or part == "." or part == ".."
           or not _SAFE_COMPONENT.fullmatch(part) or ".." in part
           for part in parts):
        return False
    return True


def _pin_data(entry: ModelEntry, problem: tuple[str, str, str]) -> dict:
    reason, file_name, detail = problem
    return {"model": entry.id, "reason": reason, "file": file_name,
            "detail": detail}


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
        files=(ModelFile(
            "sam2.1_hiera_tiny.pt",
            # Measured 2026-11-18 three ways that agree: the pinned URL streams
            # 156,008,466 bytes to this digest, HuggingFace's LFS object id for
            # the same path is identical, and so is the copy this app installed
            # from the URL on 2026-11-08. Downloading is still refused by the
            # JSON entry's `unverifiableReason`: `sam2` is in neither
            # requirements.lock nor the `models` extra, so these weights have no
            # runtime to load them.
            "7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69",
            156_008_466,
            url="https://dl.fbaipublicfiles.com/segment_anything_2/092824/"
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
            # A deliberate research switch: it only ever bypasses the licence
            # gate, never a size or digest check, and the app strips it from the
            # worker's inherited environment so an exported shell variable
            # cannot open the gate in a real launch. Set it on the worker's own
            # command line to evaluate an uncleared model.
            allow_uncleared = os.environ.get("RETOUCH_AI_EVAL_MODELS") == "1"
        self.allow_uncleared = allow_uncleared
        # Shared leases held for the process lifetime: a loaded model cannot be
        # deleted or replaced under the running job, and the kernel releases
        # them if this process dies.
        self._leases: dict[tuple[str, str], int] = {}
        # Artifact identity -> (catalog generation, digest). Memoising the hash
        # proof is what makes a verified load affordable: 4.6 GB of FLUX weights
        # costs ~2.2 s once per process, which a job can pay and a capability
        # poll cannot. The key covers the device, inode, size, mtime **and ctime**
        # — an in-place rewrite that preserves the length and a hand-set mtime
        # still moves the change time — plus the catalog generation and the
        # expected digest, so editing a pin invalidates every proof. A proof is
        # only ever *added* after a file has actually been hashed; nothing can
        # seed it from outside.
        self._proofs: dict[tuple, tuple[tuple, str]] = {}

    @staticmethod
    def _generation() -> tuple:
        """Identity of the catalog data currently in force.

        `_pins_of` reads the module-level `CATALOG`, so a test (or a runtime
        amendment) that replaces the tuple changes this value and with it every
        cached digest proof. The tuple is stored rather than a builtin `hash`
        because those are salted per process — fine for one worker, but it would
        make the value unprintable in a diagnostic and incomparable across runs.
        """
        return tuple(_pins_of(entry) for entry in CATALOG)

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

    def _require_licensed(self, entry: ModelEntry) -> None:
        if not entry.commercial_ok and not self.allow_uncleared:
            raise WorkerError(
                LICENSE_BLOCKED,
                f"{entry.id} is not cleared for commercial use ({entry.license_id})",
                {"model": entry.id, "license": entry.license_id},
            )

    def _resolve_under_lease(self, entry: ModelEntry) -> tuple[Path, str]:
        """Lease the install and return `(model_root, lease identity)`.

        Existence is answered before integrity on purpose: an uninstalled model
        must stay `-32011` so the UI can offer a download, while a damaged or
        unverifiable one must not be called missing, because no download repairs
        a catalog pin.
        """
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
        identity = LEGACY_LEASE if model_root == flat_root else model_root.name
        return model_root, identity

    def _check_sizes(self, entry: ModelEntry,
                     model_root: Path) -> dict[str, object]:
        """Stat every listed file; return the stamps a digest pass can reuse.

        Existence answers first (`MODEL_MISSING`, so the UI can offer a download),
        then length (`CHECKSUM_MISMATCH`). A refused load must not keep its lease,
        which is why neither raise happens inside a `with` that holds it.
        """
        stamps: dict[str, object] = {}
        for spec in entry.files:
            target = model_root / spec.path
            try:
                stamp = target.stat()
            except OSError:
                raise WorkerError(
                    MODEL_MISSING, f"{entry.id} is not installed",
                    {"model": entry.id, "missing": spec.path,
                     "download": entry.source, "reason": "not-installed"})
            if os.path.islink(target):
                # The recorded pins would be checked against whatever the link
                # points at, while a loader that reopens by name can land
                # somewhere else. A store path must be a regular file.
                raise WorkerError(
                    CHECKSUM_MISMATCH,
                    f"{entry.id} {spec.path} is a symlink, so its bytes cannot be "
                    "pinned to this install",
                    {"model": entry.id, "file": spec.path,
                     "reason": REASON_UNSAFE_PATH})
            if stamp.st_size != spec.bytes:
                # The same condition capability.list reports as blocked. A
                # submission that names only a job kind must not load a file
                # the record says is damaged. The lease is dropped by the caller.
                raise WorkerError(CHECKSUM_MISMATCH,
                                  f"{entry.id} failed its recorded size check",
                                  {"model": entry.id, "file": spec.path,
                                   "reason": REASON_SIZE,
                                   "expected_bytes": spec.bytes,
                                   "actual_bytes": stamp.st_size})
            stamps[spec.path] = stamp
        return stamps

    def require(self, model_id: str) -> Path:
        """Resolve and lease an install, checking recorded sizes only.

        This accessor reads **no file contents**. It exists for reporting —
        `capability.list`, the model manager, launch health — where hashing 4.6 GB
        per poll is not affordable. No path that hands bytes to a runtime may use
        it: every engine loader calls `require_verified`, and a test asserts that
        split. It still refuses a malformed or incomplete pin set, because a size
        check silently skipped for a null pin is how this method used to be
        fail-open.

        The order of the three refusals is what the host's routing keys on: an
        uncleared licence first (`-32010`, so a licence answer never depends on
        disk state), then the catalog's own defect (`-32021`, which no download
        can repair), then the install itself (`-32011` missing, `-32019` damaged).
        """
        entry = self.get(model_id)
        self._require_licensed(entry)
        problem = pin_problem(entry)
        if problem is not None:
            raise WorkerError(CATALOG_INVALID, problem[2], _pin_data(entry, problem))
        model_root, identity = self._resolve_under_lease(entry)
        try:
            self._check_sizes(entry, model_root)
        except WorkerError:
            self._release(entry, identity)
            raise
        return model_root

    def _verify_digests(self, entry: ModelEntry, model_root: Path,
                        identity: str, stamps: dict) -> None:
        """Hash every listed file against its pin, releasing the lease on refusal."""
        generation = self._generation()
        for spec in entry.files:
            expected = normalize_digest(spec.sha256)
            if expected is None:
                # Unreachable through `require`; guarded so no future caller can
                # reinstate the old `if spec.sha256 is None: continue` hole.
                self._release(entry, identity)
                problem = pin_problem(entry)
                raise WorkerError(CATALOG_INVALID,
                                  problem[2] if problem else
                                  f"{entry.id} has an unusable catalog pin",
                                  _pin_data(entry, problem) if problem
                                  else {"model": entry.id,
                                        "reason": REASON_INVALID_DIGEST})
            target = model_root / spec.path
            stamp = stamps.get(spec.path)
            if stamp is None:
                try:
                    stamp = target.stat()
                except OSError:
                    self._release(entry, identity)
                    raise WorkerError(
                        MODEL_MISSING, f"{entry.id} is not installed",
                        {"model": entry.id, "missing": spec.path,
                         "download": entry.source, "reason": "not-installed"})
            key = (self.root, entry.id, spec.path, expected, spec.bytes,
                   stamp.st_dev, stamp.st_ino, stamp.st_size, stamp.st_mtime_ns,
                   getattr(stamp, "st_ctime_ns", 0))
            if self._proofs.get(key) == (generation, expected):
                # Already proven by this process, and these are the same bytes:
                # same inode, same length, same modification *and* change time.
                continue
            try:
                actual = _sha256(target)
            except OSError:
                # The size pass stat'ed this file moments ago. A name that resolves
                # but will not open is an unreadable install, not a missing one:
                # calling it missing would offer a download over a file that is
                # sitting right there.
                self._release(entry, identity)
                raise WorkerError(
                    CHECKSUM_MISMATCH,
                    f"{entry.id} could not be read, so it cannot be verified",
                    {"model": entry.id, "file": spec.path,
                     "reason": REASON_UNREADABLE})
            if actual != expected:
                # The lease is dropped so the damaged install can be reinstalled
                # or deleted; the host maps this code to E_MODEL_UNVERIFIED.
                self._release(entry, identity)
                raise WorkerError(CHECKSUM_MISMATCH,
                                  f"{entry.id} failed its recorded checksum",
                                  {"model": entry.id, "file": spec.path,
                                   "reason": REASON_DIGEST,
                                   "expected_sha256": expected,
                                   "actual_sha256": actual})
            self._proofs[key] = (generation, expected)

    def require_verified(self, model_id: str) -> Path:
        """The only accessor a job load path may use: sizes **and** digests.

        Every file the catalog lists is hashed against its recorded SHA-256
        before the loader receives a path, so a same-length substitution cannot
        reach a runtime. The proof is memoised per artifact identity for the life
        of the process, which is what makes paying ~2.2 s once for 4.6 GB of FLUX
        weights acceptable while `health()` and `capability.list` stay cheap. An
        entry whose pin is missing or malformed is refused here rather than
        loaded unchecked: there is no fallback path that trusts unverifiable
        bytes.
        """
        entry = self.get(model_id)
        self._require_licensed(entry)
        problem = pin_problem(entry)
        if problem is not None:
            raise WorkerError(CATALOG_INVALID, problem[2], _pin_data(entry, problem))
        model_root, identity = self._resolve_under_lease(entry)
        try:
            stamps = self._check_sizes(entry, model_root)
            self._verify_digests(entry, model_root, identity, stamps)
        except WorkerError:
            self._release(entry, identity)
            raise
        return model_root

    def release(self, model_id: str, model_root: Path) -> None:
        """Drop the lease `require` took, so a failed load cannot block a repair."""
        entry = self.get(model_id)
        folder = self.root / entry.id
        if model_root == folder:
            self._release(entry, LEGACY_LEASE)
        elif model_root.parent == folder:
            self._release(entry, model_root.name)

    def health(self) -> dict:
        """Cheap launch check: catalog loads, every pin is usable, sizes are whole.

        Hashing a 4.6 GB model would make launch wait minutes, so this compares
        the recorded size instead. `models verify` remains the deep check, and a
        model that is simply not installed is reported but is not a failure. An
        installed model whose entry cannot be verified at all — no size, no
        digest, a malformed digest, an empty file list — **is** a failure: it used
        to be reported `ok`, because both checks were skipped when the pin was
        null. Refusing to claim health for bytes it never checked costs nothing
        and needs no hashing.
        """
        models, ok = [], True
        for entry in CATALOG:
            problem = pin_problem(entry)
            installed = entry.installed(self.root)
            state = {"model": entry.id, "installed": installed, "ok": True}
            if problem is not None:
                # Reported for every entry, installed or not: an unusable pin is a
                # catalog fact, and a not-installed model with a bad pin must not
                # look fixable by a download. The code is the one `require` raises
                # for the same defect, so a host sees one taxonomy over the wire
                # and in the report — `-32021` is never downloadable.
                state["ok"] = False
                state["code"] = CATALOG_INVALID
                state.setdefault("problems", []).append(
                    {"file": problem[1], "reason": problem[0]})
                ok = False
            elif installed:
                try:
                    model_root = resolve_model_root(self.root, entry.id)
                except (OSError, ValueError):
                    state["ok"] = False
                    state.setdefault("problems", []).append(
                        {"file": "", "reason": "no-active-version"})
                    models.append(state)
                    ok = False
                    continue
                for spec in entry.files:
                    target = model_root / spec.path
                    try:
                        actual = target.stat().st_size
                    except OSError:
                        state["ok"] = False
                        state.setdefault("problems", []).append(
                            {"file": spec.path, "reason": "missing"})
                        continue
                    if actual != spec.bytes:
                        state["ok"] = False
                        state.setdefault("problems", []).append(
                            {"file": spec.path, "reason": "size"})
                ok = ok and state["ok"]
            models.append(state)
        return {"ok": ok, "root": str(self.root), "models": models}

    def verify(self, model_id: str) -> dict:
        """The deep, on-demand scan: every listed file, size then digest.

        The shape `{"model", "checked", "failed", "ok"}` is consumed by the model
        manager and `models verify`, so a mismatch is reported here rather than
        raised. `checked` counts the files actually hashed. An entry with no
        usable pin hashes nothing, so it reports `unverifiable` and `ok: false`
        instead of the `checked: 0, ok: true` it used to return.
        """
        entry = self.get(model_id)
        problem = pin_problem(entry)
        if problem is not None:
            return {"model": entry.id, "checked": 0,
                    "failed": [{"file": problem[1], "reason": problem[0]}],
                    "ok": False, "unverifiable": True}
        try:
            model_root = resolve_model_root(self.root, entry.id)
        except (OSError, ValueError) as error:
            raise WorkerError(MODEL_MISSING, f"{entry.id} has no usable active version",
                              {"model": entry.id, "reason": str(error)})
        checked, failed = 0, []
        for spec in entry.files:
            expected = normalize_digest(spec.sha256)
            target = model_root / spec.path
            try:
                actual_size = target.stat().st_size
            except OSError:
                failed.append({"file": spec.path, "reason": "missing"})
                continue
            if actual_size != spec.bytes:
                # A short or padded file fails on length before it is hashed, so
                # the report says which of the two records it broke.
                failed.append({"file": spec.path, "reason": REASON_SIZE,
                               "expected_bytes": spec.bytes,
                               "actual_bytes": actual_size})
                continue
            if _sha256(target) != expected:
                failed.append({"file": spec.path, "reason": "checksum"})
                checked += 1
                continue
            checked += 1
        return {"model": entry.id, "checked": checked, "failed": failed,
                "ok": not failed}
