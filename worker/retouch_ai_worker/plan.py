"""Download manifest computation: what would be fetched, and its consent hash.

Pure data and hashing — no network, no filesystem. The server can answer
`models.plan` without pulling any transfer code into the job process.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass

from .catalog import Catalog
from .protocol import LICENSE_BLOCKED, MODEL_MISSING, WorkerError


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
    return {**payload, "manifest_hash": digest}
