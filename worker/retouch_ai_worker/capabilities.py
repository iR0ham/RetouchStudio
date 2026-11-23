"""Truthful capability reporting for the macOS worker adapter.

The vocabulary is frozen in W5-0 §3.2 and versioned as `capabilities/1`. A
capability is `supported` only when the adapter provides it, a catalog model is
installed at a recorded version and passes the quick size check, and a recorded
run binds that platform, provider, model id and version to a valid artifact
(DR-4). A fourth condition decides before the other three: the Python package
that loads the model has to be importable in this interpreter. Weights with no
runtime to run on are a blocked capability, not a supported one that fails.
A fifth condition decides before everything: a model whose permitted-use record
does not admit distribution is a blocked capability, never a `requires_model`
download offer. Everything else carries a reason: `requires_model`, `blocked`
or `unsupported`.

This module never loads a model, never takes a lease and never hashes weights:
listing capabilities must stay cheap and must not disturb a running job. The
deep check remains the Model Manager's verify action.
"""
from __future__ import annotations

import importlib.util
import json
import os
import platform
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from .catalog import (Catalog, ModelEntry, pin_problem, resolve_model_root,
                      unlisted_payload)
from .protocol import CONTRACT_VERSION, WorkerError

VOCABULARY = "capabilities/1"
SUPPORTED = "supported"
REQUIRES_MODEL = "requires_model"
BLOCKED = "blocked"
UNSUPPORTED = "unsupported"
PROVIDER = "macos-python"

_EVIDENCE_ENV = "RETOUCH_AI_CAPABILITY_EVIDENCE"
_DEFAULT_EVIDENCE = Path(__file__).with_name("capability-evidence.json")


@dataclass(frozen=True)
class Spec:
    id: str
    job: str | None = None
    models: tuple[str, ...] = ()
    packages: tuple[str, ...] = ()
    state: str | None = None
    reason: str | None = None


# Every capability in the frozen vocabulary gets one record. A fixed state is
# used where the adapter's answer does not depend on an installed model.
CAPABILITIES: tuple[Spec, ...] = (
    Spec("face.analysis", state=UNSUPPORTED,
         reason="the worker does not run face analysis; the macOS host uses Vision"),
    Spec("face.parsing", state=UNSUPPORTED,
         reason="no learned face-parsing model is adopted (follow-on F2)"),
    Spec("mask.subject", state=UNSUPPORTED,
         reason="the worker does not run person segmentation; the macOS host uses Vision"),
    Spec("mask.click", "mask", ("sam2.1-hiera-tiny",), packages=("sam2",)),
    Spec("matte.fine", state=BLOCKED,
         reason="no fine-matte model with cleared commercial rights is adopted (S2)"),
    Spec("inpaint.spot", "patch_edit", ("migan",)),
    Spec("inpaint.object", "patch_edit", ("flux2-klein-4b-q4",)),
    Spec("generative.edit", "patch_edit", ("flux2-klein-4b-q4",)),
    Spec("generative.reimagine", "patch_edit", ("flux2-klein-4b-q4",)),
    Spec("generative.outpaint", state=BLOCKED,
         reason="no licensed outpainting engine; the product refuses outpainting"),
    Spec("background.replace", state=UNSUPPORTED,
         reason="the worker has no composite path; the macOS host composes over Vision"),
    Spec("upscale.2x", state=UNSUPPORTED,
         reason="2× output is not implemented (follow-on U1)"),
    Spec("upscale.4x", "upscale", ("swin2sr-x4",)),
    Spec("enhance.photo", state=UNSUPPORTED,
         reason="classical enhancement only; no AI enhancer model (follow-on E1)"),
    Spec("restore.photo", state=UNSUPPORTED,
         reason="classical restoration only; no AI restoration model (follow-on E1)"),
    Spec("portrait.ai", state=UNSUPPORTED,
         reason="no AI portrait model; classical portrait processing stays the default (P1)"),
)

_BY_ID = {spec.id: spec for spec in CAPABILITIES}


def current_platform() -> str:
    return "macos-arm64" if platform.machine() == "arm64" else "macos-x64"


def load_evidence(path: Path | None = None) -> tuple[dict, ...]:
    """The recorded runs that may justify `supported`.

    A missing or unreadable ledger means no capability is supported; it never
    means the opposite. Malformed entries are ignored for the same reason.
    """
    ledger = path or Path(os.environ.get(_EVIDENCE_ENV, _DEFAULT_EVIDENCE))
    try:
        data = json.loads(Path(ledger).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ()
    if data.get("schema") != "retouchstudio.capability-evidence/1":
        return ()
    entries = []
    for entry in data.get("entries") or []:
        if not isinstance(entry, dict):
            continue
        required = ("capabilityId", "platform", "provider", "modelId",
                    "modelVersion", "evidence")
        if not all(isinstance(entry.get(key), str) and entry[key] for key in required):
            continue
        entries.append({key: entry[key] for key in required})
    return tuple(entries)


def _evidence_for(entries: tuple[dict, ...], spec: Spec, platform_name: str,
                  provider: str, model_id: str, version: str) -> str | None:
    for entry in entries:
        if (entry["capabilityId"] == spec.id and entry["platform"] == platform_name
                and entry["provider"] == provider and entry["modelId"] == model_id
                and entry["modelVersion"] == version):
            return entry["evidence"]
    return None


def _importable(name: str) -> bool:
    """Whether this interpreter can load the top-level package `name`.

    `find_spec` resolves the module without executing it, so the check stays
    cheap and cannot start a GPU context — which is the whole reason it is done
    here instead of in the job.
    """
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


def _inspect(catalog: Catalog, model_id: str) -> tuple[str, str | None, str | None]:
    """Return `(state, version, reason)` for one model without taking a lease.

    `state` is `ok`, `missing`, `legacy`, `damaged` or `unverifiable`.
    """
    entry = catalog.get(model_id)
    # One admission rule with the load path: an entry whose pin set is absent,
    # incomplete or malformed cannot be bound to a capability. Before this, the
    # two layers disagreed — `_inspect` called a pinless entry unverifiable while
    # `require_verified` loaded it on size alone.
    problem = pin_problem(entry)
    if problem is not None:
        return "unverifiable", None, (
            f"{entry.id} {problem[1]}: {problem[2]} "
            "(DR-5, catalog defect; no download can repair it)")
    flat = catalog.root / entry.id
    try:
        root = resolve_model_root(catalog.root, entry.id)
    except FileNotFoundError:
        return "missing", None, f"{entry.id} is not installed"
    except (OSError, ValueError):
        return "damaged", None, f"{entry.id} has an unreadable active version"
    if root == flat:
        if not flat.is_dir():
            return "missing", None, f"{entry.id} is not installed"
        return "legacy", None, (
            f"{entry.id} is installed without a version; adopt it in the model "
            "manager before a capability can bind it")
    for spec in entry.files:
        target = root / spec.path
        if target.is_symlink():
            # The size below is read through the link, so it cannot describe the
            # bytes this install pins. `_check_sizes` refuses the load, and a
            # capability that advertised `supported` over that refusal would make
            # the same two-layer disagreement the pin admission rule closes.
            return "damaged", root.name, (
                f"{entry.id} {root.name} has {spec.path} as a symlink rather than "
                "a regular file; verify it in the model manager")
        try:
            actual = target.stat().st_size
        except OSError:
            return "damaged", root.name, (
                f"{entry.id} {root.name} is missing {spec.path}; install or verify it")
        if actual != spec.bytes:
            # Unconditional: `pin_problem` already guarantees a recorded size, so
            # a null here can only mean the catalog changed mid-report. A check
            # silently skipped on a null pin is exactly how this layer used to be
            # fail-open.
            return "damaged", root.name, (
                f"{entry.id} {root.name} failed its size check; verify it in the "
                "model manager")
    extra = unlisted_payload(entry, root)
    if extra:
        # A file the catalog does not name is invisible to every pin, yet the
        # convention-following loaders here would prefer it (a dropped
        # `model.safetensors` beats the pinned `pytorch_model.bin`). The load path
        # refuses it, so the report must too.
        return "damaged", root.name, (
            f"{entry.id} {root.name} holds {', '.join(extra)} which the catalog "
            "does not list; verify it in the model manager")
    return "ok", root.name, None


def permission_refusal(entry: ModelEntry | None,
                       catalog: Catalog) -> str | None:
    """The sentence refusing a model on permission grounds, or None.

    One source for the two places that have to agree. `report` publishes the
    blocked capability, and the job gate in `server.py` refuses a named
    capability — if those two derived the answer separately, the report could
    say "no established permission" while the gate answered with the generic
    class, which is the shape the host routes to Manage Models. The order
    matches `report`: a record that fails validation is a catalogue defect with
    its own code, so it is not reported as a permission refusal here, and an
    excluded model is refused whatever the evaluation switch says.
    """
    if entry is None:
        return None
    try:
        entry.validate()
    except ValueError:
        return None
    excluded = entry.permitted_use.excluded
    if excluded:
        return (f"{entry.id} is excluded ({', '.join(excluded)} terms refuse "
                f"distribution), so no configuration downloads or runs it")
    if not catalog.allow_uncleared and not entry.permitted_use.admitted:
        verdict = entry.permitted_use.weights.verdict
        return (f"{entry.id} has no established permission for public "
                f"non-commercial use and distribution (weights verdict: "
                f"{verdict}), so this build will not download or run it")
    return None


def capability_permission_refusal(capability_id: str,
                                  catalog: Catalog) -> str | None:
    """Why permission alone blocks this capability, or None if it does not.

    A capability with no model behind it — a fixed `unsupported` or a `blocked`
    with nothing installed to refuse — can never be a permission refusal, and an
    id the catalog does not carry is the caller's bug, not a licence answer.
    """
    spec = next((item for item in CAPABILITIES if item.id == capability_id), None)
    if spec is None or not spec.models:
        return None
    try:
        entry = catalog.get(spec.models[0])
    except WorkerError:
        return None
    return permission_refusal(entry, catalog)


def _record(spec: Spec, state: str, provider: str, model_id: str | None = None,
            version: str | None = None, evidence: str | None = None,
            reason: str | None = None) -> dict:
    record = {"capabilityId": spec.id, "state": state, "provider": provider}
    if model_id is not None:
        record["modelId"] = model_id
    if version is not None:
        record["modelVersion"] = version
    if state == SUPPORTED:
        record["evidence"] = evidence
    else:
        # Every state other than supported must say why (W5-0 §3.3).
        record["reason"] = reason or "the adapter does not provide this capability"
    return record


def report(catalog: Catalog, evidence: tuple[dict, ...] | None = None,
           platform_name: str | None = None, provider: str = PROVIDER,
           importable: Callable[[str], bool] | None = None) -> dict:
    platform_name = platform_name or current_platform()
    ledger = load_evidence() if evidence is None else evidence
    have = _importable if importable is None else importable
    records = []
    for spec in CAPABILITIES:
        if spec.state is not None:
            records.append(_record(spec, spec.state, provider, reason=spec.reason))
            continue
        model_id = spec.models[0]
        entry = catalog.get(model_id)
        try:
            entry.validate()
        except ValueError as error:
            records.append(_record(
                spec, BLOCKED, provider, model_id,
                reason=f"{error}, so this build will not download or run it"))
            continue
        refusal = permission_refusal(entry, catalog)
        if refusal is not None:
            # Asked before the install state: a licence refusal must not become
            # a download offer (`requires_model`) for the same weights. The same
            # helper answers the job gate, so the report and the refusal cannot
            # drift apart on which class a permission is.
            records.append(_record(spec, BLOCKED, provider, model_id,
                                   reason=refusal))
            continue
        absent = [name for name in spec.packages if not have(name)]
        if absent:
            # Asked before the model, because downloading cannot answer it.
            records.append(_record(
                spec, BLOCKED, provider, model_id,
                reason=f"this worker cannot import {', '.join(absent)}, so "
                       f"{model_id} has nothing to run on"))
            continue
        state, version, reason = _inspect(catalog, model_id)
        if state == "missing":
            records.append(_record(spec, REQUIRES_MODEL, provider, model_id,
                                   reason=reason))
            continue
        if state in ("unverifiable", "legacy", "damaged"):
            records.append(_record(spec, BLOCKED, provider, model_id,
                                   version=version, reason=reason))
            continue
        found = _evidence_for(ledger, spec, platform_name, provider, model_id,
                              version or "")
        if found:
            records.append(_record(spec, SUPPORTED, provider, model_id, version,
                                   evidence=found))
        else:
            records.append(_record(
                spec, BLOCKED, provider, model_id, version=version,
                reason=(f"no recorded run binds {model_id} {version} to "
                        f"{platform_name}/{provider}")))
    return {"contractVersion": CONTRACT_VERSION, "vocabulary": VOCABULARY,
            "platform": platform_name, "provider": provider,
            "capabilities": records}


def record(capability_id: str, catalog: Catalog,
           evidence: tuple[dict, ...] | None = None,
           platform_name: str | None = None, provider: str = PROVIDER) -> dict | None:
    for item in report(catalog, evidence, platform_name, provider)["capabilities"]:
        if item["capabilityId"] == capability_id:
            return item
    return None


def job_capability(kind: str) -> tuple[Spec, ...]:
    return tuple(spec for spec in CAPABILITIES if spec.job == kind)
