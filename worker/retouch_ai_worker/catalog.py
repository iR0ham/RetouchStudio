"""Model catalog: what the worker may load, and under which licence.

The catalog is data, not comments. Every entry carries an SPDX licence id and a
`permitted_use` record that states, separately for the model's code, its weight
files and its training data, the use class this product needs, the three
permission axes the owner's 2026-11-22 mandate separates (may an end user
acquire the file from where we ship it; may we publish its URL, size and
SHA-256 and install it; is the intended non-commercial use permitted), where
the statement came from, the evidence URL and read date, and a licence verdict
drawn from the four statuses the mandate allows.

The boolean this replaced could not express "we do not know", and that is how an
inferred permission once became an approval. The record makes unknown a
first-class value and the validator refuses the two silent upgrades: inferred
evidence may not record a granted permission, and a verdict of `unknown` may not
be admitted to run inference. A model that is missing on disk is a distinct
error from one whose licence is not established, so the UI can offer "download"
in one case and nothing in the other.
"""
from __future__ import annotations

import fcntl
import hashlib
import datetime
import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

from .protocol import (BUSY, CHECKSUM_MISMATCH, LICENSE_BLOCKED, MODEL_MISSING,
                       UNKNOWN_MODEL, WorkerError)

MODEL_ROOT = Path(os.environ.get(
    "RETOUCH_AI_MODELS",
    Path.home() / "Library" / "Application Support" / "RetouchStudio" / "AI" / "models",
))
_HF_FLUX = "https://huggingface.co/mflux-community/flux2-klein-4b-mflux-q4/resolve/main/"
_HF_SWIN2SR = ("https://huggingface.co/caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr/"
               "resolve/main/")

# The one use class this product needs. Every recorded term must state it, so a
# grant for a different use (commercial resale, for example) cannot be read as
# covering this application.
REQUIRED_USE = "public-non-commercial-use-and-distribution"

# The owner's four statuses. Nothing outside this set is a verdict.
APPROVED = "approved"
APPROVED_WITH_CONDITIONS = "approved-with-conditions"
UNKNOWN = "unknown"
EXCLUDED = "excluded"
VERDICTS = (APPROVED, APPROVED_WITH_CONDITIONS, UNKNOWN, EXCLUDED)

# Who made the statement. `not-established` records that the search happened and
# produced no usable statement; it is the honest shape of "we do not know", and
# it is what an existing record becomes when it cannot survive the new schema.
STATED_BY_RIGHTS_HOLDER = "rights-holder"
STATED_BY_INFERRED = "inferred"
STATED_BY_NOT_ESTABLISHED = "not-established"
STATED_BY = (STATED_BY_RIGHTS_HOLDER, STATED_BY_INFERRED,
             STATED_BY_NOT_ESTABLISHED)

# The dossier's own read date. A record carries the date it was read, never the
# date of the commit that copied it.
LICENCE_READ_ON = "2026-11-21"


@dataclass(frozen=True)
class ModelFile:
    path: str
    sha256: str | None = None
    bytes: int | None = None
    url: str | None = None


@dataclass(frozen=True)
class UseCondition:
    """A condition attached to an `approved-with-conditions` verdict.

    `met` is the recorded claim that the project has actually satisfied it. The
    validator refuses an empty list and any unmet entry, so the status can never
    stand in for work that has not been done.
    """
    text: str
    met: bool


@dataclass(frozen=True)
class ArtefactTerms:
    """What the recorded evidence says about one artefact (code, weights, data).

    The three permission axes are stored separately because they are answered
    separately under the mandate, and collapsing them to one boolean is exactly
    the conflation this record exists to prevent:

    - `can_acquire`: the end user may obtain this file from `evidence_url`.
    - `can_redistribute`: the project may publish that URL, the recorded size
      and SHA-256 and install from it. This application mirrors no bytes, so
      this axis says nothing about mirroring.
    - `can_use`: the recorded use class is permitted.

    A False answer on any axis is a refusal, so the validator requires the
    `excluded` verdict for it. `permitted` is derived from the three, and
    `admitted` is what the load gate asks.
    """
    use: str
    can_acquire: bool | None
    can_redistribute: bool | None
    can_use: bool | None
    stated_by: str
    evidence_url: str
    read_on: str
    verdict: str
    conditions: tuple[UseCondition, ...] = ()
    # Attribution/notice text to reproduce if a file were ever mirrored or
    # bundled. Recorded evidence, not a claim that mirroring happens.
    notice: str | None = None
    # Why the verdict is what it is, or why the position is not established.
    note: str | None = None

    @property
    def permitted(self) -> bool | None:
        """True only when every permission axis is granted; unknown otherwise.

        A single refusal makes it False; a single blank makes it None, because
        "we know one answer and not the others" is still not a permission.
        """
        axes = (self.can_acquire, self.can_redistribute, self.can_use)
        if any(value is False for value in axes):
            return False
        if all(value is True for value in axes):
            return True
        return None

    @property
    def admitted(self) -> bool:
        """Whether this artefact alone satisfies the admission rule."""
        return (
            self.verdict in (APPROVED, APPROVED_WITH_CONDITIONS)
            and self.permitted is True
            and all(condition.met for condition in self.conditions)
        )

    def validate(self) -> None:
        """Rejects every record the mandate would otherwise have to infer.

        Called for the shipped table at import time and again before a load, so
        an edited table can never be admitted by accident. Messages name the
        field, because this is the audit trail when something is wrong.
        """
        if self.use != REQUIRED_USE:
            raise ValueError(
                f"records use {self.use!r}, not the required {REQUIRED_USE!r}")
        if self.stated_by not in STATED_BY:
            raise ValueError(f"has an unknown statement source {self.stated_by!r}")
        if self.verdict not in VERDICTS:
            raise ValueError(f"has an unknown licence verdict {self.verdict!r}")
        for name, value in (("can_acquire", self.can_acquire),
                            ("can_redistribute", self.can_redistribute),
                            ("can_use", self.can_use)):
            if value is not None and not isinstance(value, bool):
                raise ValueError(f"has a non-boolean {name} {value!r}")
        if not self.evidence_url:
            raise ValueError("has no evidence URL")
        if not self.read_on:
            raise ValueError("has no evidence read date")
        _check_read_on(self.read_on)

        axes = (self.can_acquire, self.can_redistribute, self.can_use)
        if self.stated_by == STATED_BY_INFERRED and any(value is True for value in axes):
            # The central rule: an inference is never a grant.
            raise ValueError("records a permitted axis from inferred evidence")
        if self.stated_by == STATED_BY_NOT_ESTABLISHED:
            if self.verdict != UNKNOWN or any(value is not None for value in axes):
                raise ValueError(
                    "marks the statement not established but records a decision")
        if any(value is False for value in axes) and self.verdict != EXCLUDED:
            raise ValueError("records a refused permission without the excluded verdict")
        if self.verdict == EXCLUDED and any(value is True for value in axes):
            raise ValueError("is excluded but records a granted permission")
        if self.permitted is True and self.verdict not in (APPROVED,
                                                           APPROVED_WITH_CONDITIONS):
            raise ValueError("records every permission without an approving verdict")
        if self.verdict in (APPROVED, APPROVED_WITH_CONDITIONS) and self.permitted is not True:
            raise ValueError("approves the artefact without every permission granted")
        if self.verdict == APPROVED and self.conditions:
            raise ValueError("is approved but carries conditions")
        if self.verdict == APPROVED_WITH_CONDITIONS:
            if not self.conditions:
                raise ValueError("is approved with conditions but lists none")
            if not all(condition.met for condition in self.conditions):
                raise ValueError("is approved with conditions but a condition is unmet")
        if self.verdict == UNKNOWN and not (self.note or "").strip():
            raise ValueError("records an unknown verdict without saying what is missing")

    def to_json(self) -> dict:
        """The wire shape shared with the app catalog, field for field."""
        return {
            "use": self.use,
            "canAcquire": self.can_acquire,
            "canRedistribute": self.can_redistribute,
            "canUse": self.can_use,
            "statedBy": self.stated_by,
            "evidenceUrl": self.evidence_url,
            "readOn": self.read_on,
            "verdict": self.verdict,
            "conditions": [{"text": item.text, "met": item.met}
                           for item in self.conditions],
            "notice": self.notice,
            "note": self.note,
        }


@dataclass(frozen=True)
class PermittedUse:
    """The three artefact records a model entry carries."""
    code: ArtefactTerms
    weights: ArtefactTerms
    training_data: ArtefactTerms

    def validate(self) -> None:
        for name, terms in (("code", self.code), ("weights", self.weights),
                            ("training data", self.training_data)):
            try:
                terms.validate()
            except ValueError as error:
                raise ValueError(f"{name} {error}") from None

    @property
    def excluded(self) -> tuple[str, ...]:
        """Artefacts whose verdict is `excluded`, in record order."""
        return tuple(
            name for name, terms in (("code", self.code),
                                     ("weights", self.weights),
                                     ("training data", self.training_data))
            if terms.verdict == EXCLUDED)

    @property
    def admitted(self) -> bool:
        """The load gate.

        The weight file is the artefact this product distributes and runs, so
        the mandate's "unclear weight permissions must not enter a distributable
        build" is enforced on its record. Code and training-data terms are
        recorded and may remain unknown — that is the dossier's residual-risk
        position — but an excluded code or dataset verdict refuses the model,
        and an approved-with-conditions record can never pass with an unmet
        condition because `validate()` rejects it first.
        """
        return self.weights.admitted and not self.excluded

    def to_json(self) -> dict:
        return {
            "code": self.code.to_json(),
            "weights": self.weights.to_json(),
            "trainingData": self.training_data.to_json(),
            "admitted": self.admitted,
        }


def _check_read_on(value: str) -> None:
    """An ISO-8601 calendar date, not free text nobody can compare later."""
    parts = value.split("-")
    if (len(parts) != 3 or len(parts[0]) != 4 or len(parts[1]) != 2
            or len(parts[2]) != 2
            or not all(part.isdigit() for part in parts)):
        raise ValueError(f"has a read date that is not an ISO-8601 date: {value!r}")
    try:
        datetime.date(int(parts[0]), int(parts[1]), int(parts[2]))
    except ValueError:
        raise ValueError(f"has an impossible read date: {value!r}") from None


@dataclass(frozen=True)
class ModelEntry:
    id: str
    name: str
    task: str
    license_id: str
    permitted_use: PermittedUse
    source: str
    files: tuple[ModelFile, ...] = field(default_factory=tuple)
    notes: str = ""

    def validate(self) -> None:
        try:
            self.permitted_use.validate()
        except ValueError as error:
            raise ValueError(f"{self.id} {error}") from None

    def public(self, root: Path) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "task": self.task,
            "license": self.license_id,
            "installed": self.installed(root),
            "source": self.source,
            "notes": self.notes,
            "bytes": sum(f.bytes or 0 for f in self.files) or None,
            # The whole recorded position, not a summary: the host's consent
            # surface and the cross-surface test read every field.
            "permitted_use": self.permitted_use.to_json(),
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


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


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


def _terms(*, verdict: str, stated_by: str, evidence_url: str,
           can_acquire: bool | None = None,
           can_redistribute: bool | None = None,
           can_use: bool | None = None,
           conditions: tuple[UseCondition, ...] = (),
           notice: str | None = None,
           note: str | None = None) -> ArtefactTerms:
    """Compact constructor so the table states its values and nothing else."""
    return ArtefactTerms(
        use=REQUIRED_USE,
        can_acquire=can_acquire,
        can_redistribute=can_redistribute,
        can_use=can_use,
        stated_by=stated_by,
        evidence_url=evidence_url,
        read_on=LICENCE_READ_ON,
        verdict=verdict,
        conditions=conditions,
        notice=notice,
        note=note,
    )


def _approved(evidence_url: str, *, notice: str | None = None,
              note: str | None = None) -> ArtefactTerms:
    """A statement made by the rights holder that grants all three axes."""
    return _terms(
        verdict=APPROVED,
        stated_by=STATED_BY_RIGHTS_HOLDER,
        evidence_url=evidence_url,
        can_acquire=True,
        can_redistribute=True,
        can_use=True,
        notice=notice,
        note=note,
    )


def _not_established(evidence_url: str, *, note: str,
                     stated_by: str = STATED_BY_NOT_ESTABLISHED,
                     notice: str | None = None) -> ArtefactTerms:
    """The search happened and produced no usable statement.

    Axes stay blank rather than false: blank means "not known", false means
    "refused", and only the latter is an exclusion.
    """
    return _terms(
        verdict=UNKNOWN,
        stated_by=stated_by,
        evidence_url=evidence_url,
        notice=notice,
        note=note,
    )


CATALOG: tuple[ModelEntry, ...] = (
    ModelEntry(
        id="flux2-klein-4b-q4",
        name="FLUX.2 klein 4B (q4)",
        task="generative-edit",
        license_id="Apache-2.0",
        permitted_use=PermittedUse(
            # No separate code-licence read exists for this entry in the
            # dossier. Recording the entry-level codeLicense string as a grant
            # would invent one, so the artefact is marked not established; the
            # weights record below is what the load gate enforces.
            code=_not_established(
                "https://huggingface.co/mflux-community/flux2-klein-4b-mflux-q4",
                note="The dossier records the FLUX.2-klein-4B weights grant at this "
                     "repository and no separate code-licence read for this entry. The "
                     "entry's codeLicense string is preserved unchanged."),
            weights=_approved(
                "https://huggingface.co/mflux-community/flux2-klein-4b-mflux-q4",
                notice="Apache-2.0. Redistributing or mirroring these weights requires a "
                       "copy of the Apache-2.0 licence, the retained copyright and licence "
                       "notices, a statement of changes, and any NOTICE text from the "
                       "source repository.",
                note="The FLUX.2-klein-4B card states the weights are open for commercial "
                     "use under Apache-2.0, so the grant is explicit rather than inferred "
                     "from a repository tag."),
            training_data=_not_established(
                "https://huggingface.co/mflux-community/flux2-klein-4b-mflux-q4",
                note="The dossier records no training-data row for this entry, so no "
                     "dataset terms are asserted."),
        ),
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
        permitted_use=PermittedUse(
            code=_approved(
                "https://github.com/facebookresearch/sam2",
                note="Apache-2.0, recorded pin @2b90b9f in Docs/AI_RUNTIME.md §6 "
                     "(dossier §3.1)."),
            weights=_approved(
                "https://huggingface.co/facebook/sam2.1-hiera-tiny",
                notice="Apache-2.0. Redistributing or mirroring this checkpoint requires a "
                       "copy of the Apache-2.0 licence, the retained copyright and licence "
                       "notices, a statement of changes, and any NOTICE text from "
                       "facebookresearch/sam2.",
                note="The SAM 2 README explicitly licenses the model checkpoints under "
                     "Apache-2.0, separately from the repository licence."),
            training_data=_not_established(
                "https://huggingface.co/facebook/sam2.1-hiera-tiny",
                note="SAM 2's training data is described in the paper, not as a licence "
                     "term; the position is not confirmed (dossier §3.1)."),
        ),
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
        permitted_use=PermittedUse(
            code=_approved(
                "https://raw.githubusercontent.com/mv-lab/swin2sr/main/LICENSE",
                note="Apache-2.0 LICENSE, SwinIR Authors 2021 (dossier Appendix A A27)."),
            # The only statement about the weights is the repository-level
            # `license:apache-2.0` tag on the Hugging Face repo whose sole
            # payload is the checkpoint. The previous draft recorded this as
            # usable-with-conditions with `explicit: false`; under the owner's
            # 2026-11-22 policy an inferred tag is not sufficient, and inferred
            # evidence may not record a granted permission. The values the
            # dossier did record are preserved below and the permission is
            # marked not established rather than dropped or upgraded.
            weights=_not_established(
                "https://huggingface.co/caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr",
                stated_by=STATED_BY_INFERRED,
                notice="Apache-2.0. Redistributing or mirroring pytorch_model.bin requires "
                       "a copy of the Apache-2.0 licence, the retained copyright notices, a "
                       "statement of changes, and any NOTICE text; the upstream code licence "
                       "carries “Copyright [2021] [SwinIR Authors]”.",
                note="The only weights statement is the repository-level license:apache-2.0 "
                     "tag on the Hugging Face repo whose sole payload is the checkpoint, so "
                     "the grant is inferred rather than authored about the weights. The "
                     "dossier's usable-with-conditions verdict does not survive the new "
                     "schema's inference rule; no permission axis is recorded."),
            training_data=_not_established(
                "https://huggingface.co/caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr",
                note="Swin2SR's own training set is not confirmed; DIV2K, the usual corpus "
                     "in this family, is made available for academic research purposes only, "
                     "which is a residual dataset risk and not a term of the recorded weight "
                     "grant (dossier §1, §2.1)."),
        ),
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
        permitted_use=PermittedUse(
            code=_approved(
                "https://raw.githubusercontent.com/Picsart-AI-Research/MI-GAN/main/LICENSE",
                note="MIT, Picsart AI Research 2024 (dossier Appendix A A26)."),
            weights=_approved(
                "https://raw.githubusercontent.com/Picsart-AI-Research/MI-GAN/main/"
                "LICENSE-WEIGHTS",
                notice="MIT. Redistributing or mirroring this ONNX requires the copyright "
                       "line and the full permission notice from LICENSE-WEIGHTS (Picsart AI "
                       "Research, 2024).",
                note="The authors ship a dedicated MIT LICENSE-WEIGHTS next to the MIT code "
                     "licence, and the ONNX is their own pipeline export."),
            training_data=_not_established(
                "https://huggingface.co/andraniksargsyan/migan",
                note="Places2 terms could not be fetched (dossier §9 item 1), so the dataset "
                     "position stays unconfirmed."),
        ),
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

# The shipped table is validated at import: a catalogue that cannot be audited
# must not start a worker that would then load its weights.
for _entry in CATALOG:
    _entry.validate()


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
        # Re-validate here rather than trusting import time: a table patched in
        # after import must be refused by the same rules. The structured refusal
        # is the licence class, never an unrelated capability failure, because
        # the caller's remedy is a licence record, not a download.
        try:
            entry.validate()
        except ValueError as error:
            raise WorkerError(
                LICENSE_BLOCKED,
                str(error),
                {"model": entry.id, "license": entry.license_id,
                 "reason": "invalid-evidence"},
            ) from None
        excluded = entry.permitted_use.excluded
        if excluded:
            # No switch admits an excluded model: the mandate says it must not
            # enter a build, and an evaluation flag is not a licence.
            raise WorkerError(
                LICENSE_BLOCKED,
                f"{entry.id} is excluded ({', '.join(excluded)} terms refuse "
                "distribution), so no configuration downloads or runs it",
                {"model": entry.id, "license": entry.license_id,
                 "reason": "excluded", "artefacts": list(excluded)},
            )
        if not entry.permitted_use.admitted and not self.allow_uncleared:
            verdict = entry.permitted_use.weights.verdict
            raise WorkerError(
                LICENSE_BLOCKED,
                f"{entry.id} has no established permission for non-commercial use "
                f"and distribution (weights verdict: {verdict})",
                {"model": entry.id, "license": entry.license_id,
                 "artefact": "weights", "verdict": verdict},
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
        identity = LEGACY_LEASE if model_root == flat_root else model_root.name
        for spec in entry.files:
            target = model_root / spec.path
            try:
                size = target.stat().st_size
            except OSError:
                self._release(entry, identity)
                raise WorkerError(MODEL_MISSING, f"{entry.id} is not installed",
                                  {"model": entry.id, "missing": spec.path,
                                   "download": entry.source})
            if spec.bytes is not None and size != spec.bytes:
                # The same size check capability.list reports as blocked. A
                # submission that names only a job kind must not load a file
                # the record says is damaged. The lease is dropped so the
                # model can still be deleted or reinstalled.
                self._release(entry, identity)
                raise WorkerError(CHECKSUM_MISMATCH,
                                  f"{entry.id} failed its recorded size check",
                                  {"model": entry.id, "file": spec.path,
                                   "expected_bytes": spec.bytes,
                                   "actual_bytes": size})
        return model_root

    def require_verified(self, model_id: str) -> Path:
        """`require`, plus the catalog's SHA-256 for every file it lists.

        The job load path uses this: hashing the weights once, just before the
        process trusts them, is 0.036 s for the 48 MB upscaler checkpoint on the
        reference Mac, and it is where the recorded digest is actually enforced
        on macOS. `require` keeps its size-only check so capability reporting,
        the model manager and launch stay cheap, and a 4.6 GB model still has
        `models verify` as its deep scan.
        """
        entry = self.get(model_id)
        model_root = self.require(model_id)
        identity = (LEGACY_LEASE if model_root == self.root / entry.id
                    else model_root.name)
        for spec in entry.files:
            if spec.sha256 is None:
                continue
            target = model_root / spec.path
            try:
                actual = _sha256(target)
            except OSError:
                self._release(entry, identity)
                raise WorkerError(MODEL_MISSING, f"{entry.id} is not installed",
                                  {"model": entry.id, "missing": spec.path,
                                   "download": entry.source})
            if actual != spec.sha256:
                # The lease is dropped so the damaged install can be reinstalled
                # or deleted; the host maps this code to E_MODEL_UNVERIFIED.
                self._release(entry, identity)
                raise WorkerError(CHECKSUM_MISMATCH,
                                  f"{entry.id} failed its recorded checksum",
                                  {"model": entry.id, "file": spec.path})
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
            if _sha256(target) != spec.sha256:
                failed.append({"file": spec.path, "reason": "checksum"})
            checked += 1
        return {"model": entry.id, "checked": checked, "failed": failed,
                "ok": not failed}
