#!/usr/bin/env python3
"""Writes each catalogue entry's permitted-use record into the host catalog.

The records are the worker catalogue's own (`retouch_ai_worker.catalog`), field
for field, so the host resource and the worker table cannot state different
licence positions. Every value there traces to the repository-owned dossier
`Docs/MODEL_LICENCES.md` (sections 0.1, 2.1, 3.1, 6, 7.1 and Appendix A); the
reads were made on 2026-11-21 and each record carries that read date.

The transform is idempotent on purpose: it parses the catalogue, replaces the
superseded `weightsEvidence` block (or appends `permitted_use`), re-serialises
in the file's own JSON style, and writes only when the bytes would change. A
second run therefore reports zero changes, which is what CI checks.

Run:  python3 Docs/licence-evidence-apply.py [--check]

`--check` writes nothing and exits 1 when the file is out of date, so CI can
prove the resource was regenerated from the catalogue instead of hand-edited.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources" / "model-catalog.json"
sys.path.insert(0, str(ROOT / "worker"))

from retouch_ai_worker.catalog import CATALOG as WORKER_CATALOG  # noqa: E402

REPLACED_KEY = "weightsEvidence"
RECORD_KEY = "permitted_use"


def snapshot(node, prefix=""):
    out = {}
    if isinstance(node, dict):
        for key, value in node.items():
            out.update(snapshot(value, f"{prefix}/{key}"))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            out.update(snapshot(value, f"{prefix}[{index}]"))
    else:
        out[prefix] = node
    return out


def records() -> dict[str, dict]:
    return {entry.id: entry.permitted_use.to_json() for entry in WORKER_CATALOG}


def rebuild(data) -> None:
    """Replaces or appends each entry's permitted-use record, in place."""
    known = records()
    ids = [entry["id"] for entry in data["entries"]]
    missing = [model_id for model_id in ids if model_id not in known]
    extra = [model_id for model_id in known if model_id not in ids]
    if missing:
        raise SystemExit(f"no permitted-use record for {missing}")
    if extra:
        raise SystemExit(f"permitted-use record for unknown entries {extra}")
    for entry in data["entries"]:
        rebuilt = collections.OrderedDict()
        for key, value in entry.items():
            if key == REPLACED_KEY:
                rebuilt[RECORD_KEY] = known[entry["id"]]
            elif key == RECORD_KEY:
                continue
            else:
                rebuilt[key] = value
        if RECORD_KEY not in rebuilt:
            rebuilt[RECORD_KEY] = known[entry["id"]]
        entry.clear()
        entry.update(rebuilt)


def render(text: str) -> str:
    data = json.loads(text, object_pairs_hook=collections.OrderedDict)
    # The two licence keys are the ones this tool owns; every other value in
    # the file must survive untouched, and that is what the snapshots prove.
    before = {key: value for key, value in snapshot(data).items()
              if f"/{REPLACED_KEY}" not in key and f"/{RECORD_KEY}" not in key}
    rebuild(data)
    after = snapshot(data)
    changed = {key: (before[key], after[key])
               for key in before
               if key in after and after[key] != before[key]}
    if changed:
        raise SystemExit(f"pre-existing values changed: {changed}")
    removed = sorted(set(before) - set(after))
    if removed:
        raise SystemExit(f"keys removed: {removed}")
    return json.dumps(data, indent=2, ensure_ascii=True) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="verify the file is current; write nothing")
    args = parser.parse_args(argv)

    text = CATALOG.read_text(encoding="utf-8")
    rendered = render(text)
    digest = hashlib.sha256(rendered.encode()).hexdigest()
    if args.check:
        if rendered != text:
            print(f"{CATALOG} is stale; run Docs/licence-evidence-apply.py",
                  file=sys.stderr)
            return 1
        print(f"OK: catalogue current, sha256 {digest}")
        return 0
    if rendered == text:
        print(f"OK: no change, sha256 {digest}")
        return 0
    CATALOG.write_text(rendered, encoding="utf-8")
    print(f"OK: catalogue updated, sha256 {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
