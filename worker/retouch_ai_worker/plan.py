"""Download manifest computation: what would be fetched, and its consent hash.

Pure data and hashing — no network, no filesystem. The server can answer
`models.plan` without pulling any transfer code into the job process.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass

from .catalog import Catalog, _pin_data, pin_problem
from .protocol import CATALOG_INVALID, LICENSE_BLOCKED, MODEL_MISSING, WorkerError


@dataclass(frozen=True)
class PlanItem:
    model: str
    path: str
    url: str
    bytes: int | None
    sha256: str | None


def manifest(model_ids: list[str], catalog: Catalog) -> dict:
    items: list[PlanItem] = []
    total = 0
    for model_id in model_ids:
        entry = catalog.get(model_id)
        try:
            entry.validate()
        except ValueError as error:
            raise WorkerError(LICENSE_BLOCKED, str(error),
                              {"model": entry.id, "license": entry.license_id,
                               "reason": "invalid-evidence"}) from None
        excluded = entry.permitted_use.excluded
        if excluded:
            raise WorkerError(
                LICENSE_BLOCKED,
                f"{entry.id} is excluded ({', '.join(excluded)} terms refuse "
                "distribution), so no configuration downloads or runs it",
                {"model": entry.id, "license": entry.license_id,
                 "reason": "excluded", "artefacts": list(excluded)})
        if not entry.permitted_use.admitted:
            verdict = entry.permitted_use.weights.verdict
            raise WorkerError(
                LICENSE_BLOCKED,
                f"{entry.id} has no established permission for non-commercial use "
                f"and distribution (weights verdict: {verdict})",
                {"model": entry.id, "license": entry.license_id,
                 "artefact": "weights", "verdict": verdict})
        # The same admission rule the load path uses, before any bytes are asked
        # for. A pinless entry would otherwise contribute `None` sizes to the
        # consent total and download weights this worker then refuses to load —
        # a paid-for transfer that can never run.
        problem = pin_problem(entry)
        if problem is not None:
            raise WorkerError(CATALOG_INVALID, problem[2], _pin_data(entry, problem))
        for spec in entry.files:
            if not spec.url:
                raise WorkerError(MODEL_MISSING,
                                  f"{entry.id}/{spec.path} has no download source",
                                  {"model": entry.id, "file": spec.path})
            items.append(PlanItem(entry.id, spec.path, spec.url, spec.bytes, spec.sha256))
            total += spec.bytes or 0
    payload = {"models": sorted(model_ids), "total_bytes": total,
               "files": [item.__dict__ for item in items]}
    digest = hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {**payload, "manifest_hash": digest,
            # Mandate §4 case 11: the worker's per-file pins are now checkable
            # against an aggregate, so a host that carries one (the app's JSON
            # catalog) can cross-check instead of trusting the sum. `sha256` is
            # not recomputed over these bytes by any host today — recorded as
            # NOT VERIFIED rather than claimed as enforced.
            "aggregate": {"size_bytes": total,
                          "files": len(items),
                          "sha256": digest}}
