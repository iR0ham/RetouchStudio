"""Model downloads: consent first, resumable, verified, atomic.

This module never runs inside a job. The worker process must have no network
code; downloads happen only when the user explicitly asks for them, and the
consent token records exactly which manifest they approved (hash of the file
list with sizes and checksums). If the manifest changes, the old consent no
longer applies.

Verification is always by SHA256 when the catalog has one. A file is written to
`<root>/.staging/...` and only moved into place after the checksum matches, so a
half-downloaded file can never be mistaken for an installed model.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path

from .catalog import Catalog
from .plan import PlanItem, manifest
from .protocol import (CHECKSUM_MISMATCH, CONSENT_REQUIRED, DOWNLOAD_FAILED,
                       WorkerError)

CHUNK = 1 << 20

__all__ = ["ConsentStore", "Downloader", "PlanItem", "manifest",
           "consent_hash_matches"]


def consent_hash_matches(plan: dict, expected: str | None) -> bool:
    """Whether a plan still is the one the owner approved.

    The app shows a manifest, then starts the downloader in a separate process.
    The catalog could change in between; passing the hash the owner saw lets the
    downloader refuse instead of installing something else.
    """
    if not expected:
        return True
    return plan.get("manifest_hash") == expected



class ConsentStore:
    """A file recording which manifest the user approved, and when."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)

    def read(self) -> dict | None:
        if not self.path.exists():
            return None
        try:
            return json.loads(self.path.read_text("utf-8"))
        except (OSError, json.JSONDecodeError):
            return None

    def grant(self, plan: dict, note: str = "") -> dict:
        record = {
            "manifest_hash": plan["manifest_hash"],
            "models": plan["models"],
            "total_bytes": plan["total_bytes"],
            "granted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "note": note,
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(record, indent=2), "utf-8")
        os.replace(tmp, self.path)
        os.chmod(self.path, 0o600)
        return record

    def revoke(self) -> None:
        self.path.unlink(missing_ok=True)

    def allows(self, plan: dict) -> bool:
        record = self.read()
        return bool(record and record.get("manifest_hash") == plan["manifest_hash"])


class Downloader:
    def __init__(self, root: Path, catalog: Catalog, consent: ConsentStore,
                 opener=None) -> None:
        self.root = Path(root)
        self.catalog = catalog
        self.consent = consent
        self.opener = opener or urllib.request.urlopen

    # --- planning -----------------------------------------------------
    def plan(self, model_ids: list[str]) -> dict:
        return manifest(model_ids, self.catalog)

    def fetch(self, model_ids: list[str], progress=None) -> dict:
        plan = self.plan(model_ids)
        if not self.consent.allows(plan):
            raise WorkerError(
                CONSENT_REQUIRED,
                "explicit consent required before downloading",
                {"manifest_hash": plan["manifest_hash"], "total_bytes": plan["total_bytes"]},
            )
        done = 0
        installed = []
        for item in plan["files"]:
            destination = self.root / item["model"] / item["path"]
            if destination.exists() and self._matches(destination, item["sha256"]):
                done += item["bytes"] or destination.stat().st_size
                continue
            self._download(item, progress=progress, offset=done,
                           total=plan["total_bytes"])
            done += item["bytes"] or destination.stat().st_size
            installed.append(str(destination.relative_to(self.root)))
        return {"installed": installed, "manifest_hash": plan["manifest_hash"]}

    # --- transfer -----------------------------------------------------
    def _download(self, item: dict, progress, offset: int, total: int) -> None:
        staging = self.root / ".staging" / item["model"] / item["path"]
        staging.parent.mkdir(parents=True, exist_ok=True)
        part = staging.with_suffix(staging.suffix + ".part")
        have = part.stat().st_size if part.exists() else 0
        if item["bytes"] is not None and have > item["bytes"]:
            part.unlink()
            have = 0

        request = urllib.request.Request(item["url"])
        if have:
            request.add_header("Range", f"bytes={have}-")
        try:
            response = self.opener(request, timeout=60)
        except urllib.error.URLError as exc:
            raise WorkerError(DOWNLOAD_FAILED, f"download failed: {exc.reason}",
                              {"url": item["url"]}) from exc
        mode = "ab" if have and getattr(response, "status", 200) == 206 else "wb"
        if mode == "wb":
            have = 0
        with response, part.open(mode) as handle:
            while True:
                block = response.read(CHUNK)
                if not block:
                    break
                handle.write(block)
                have += len(block)
                if progress:
                    progress({"file": item["path"], "received": have,
                              "offset": offset, "total": total})

        if item["sha256"] and not self._matches(part, item["sha256"]):
            part.unlink(missing_ok=True)
            raise WorkerError(CHECKSUM_MISMATCH, f"checksum mismatch for {item['path']}",
                              {"file": item["path"], "expected": item["sha256"]})
        staging.parent.mkdir(parents=True, exist_ok=True)
        if staging.exists():
            staging.unlink()
        os.replace(part, staging)
        destination = self.root / item["model"] / item["path"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.replace(staging, destination)

    @staticmethod
    def _matches(path: Path, sha256: str | None) -> bool:
        if not sha256:
            return True
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(CHUNK), b""):
                digest.update(block)
        return digest.hexdigest() == sha256
