"""Prove the runtime archive carries exactly the locked distributions.

The payload job used to compare counts: `dist-info` directories >= pinned
requirements. That passed because the venv ships 68 of them for 67 pins — the
extra is pip — and a count cannot tell that apart from a duplicated,
renamed or wrong-version distribution. A renamed directory and a missing
distribution also keep the count intact.

This reads the archive itself and compares sets:

  * expected: the `(canonical name, version)` pairs of
    `worker/requirements.lock`, parsed with the same PEP 503 normalisation
    `lock_closure.py` uses;
  * observed: `site-packages/<dir>.dist-info/METADATA` in the zip, whose
    `Name:` and `Version:` headers are compared with the lock, plus a
    `RECORD` in every dist-info directory and a directory name that matches
    the metadata it holds.

Exactly one observed distribution is allowed beyond the lock: the venv's own
`pip`. Its name and version are asserted against the interpreter that built
the environment (`--pip-version`), so a second extra cannot hide behind the
same allowance.

It also keeps the structural checks the step had: the three payload documents
and the interpreter at the archive root, a worker package, licence files
inside the dist-info directories, and the entry counts printed for the
verdict line other readers match::

    WORKER PAYLOAD: PASS (68 dist-info for 67 pins, 12 licence files, 5001 entries)

Usage:
    python worker/tools/verify_payload.py --archive runtime.zip \
        --pip-version 25.2
"""
from __future__ import annotations

import argparse
import re
import sys
import zipfile
from email.parser import HeaderParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lock_closure  # noqa: E402  (sibling tool; resolves after the insert)

WORKER_ROOT = Path(__file__).resolve().parents[1]
ROOT_DOCUMENTS = ("LICENSE", "THIRD_PARTY_NOTICES.md", "requirements.lock")
DIST_INFO = re.compile(r"^site-packages/([^/]+\.dist-info)/([^/]+)$")
LICENCE = re.compile(
    r"^site-packages/[^/]+\.dist-info/(?:licenses/)?(?:LICENSE|COPYING|NOTICE)")
PIP = "pip"


def _dist_info_dirs(names: list[str]) -> dict[str, set[str]]:
    directories: dict[str, set[str]] = {}
    for name in names:
        match = DIST_INFO.match(name)
        if match:
            directories.setdefault(match.group(1), set()).add(match.group(2))
    return directories


def _metadata(archive: zipfile.ZipFile, directory: str) -> tuple[str, str] | None:
    name = f"site-packages/{directory}/METADATA"
    try:
        text = archive.read(name).decode("utf-8", "replace")
    except KeyError:
        return None
    message = HeaderParser().parsestr(text)
    package, version = message.get("Name"), message.get("Version")
    if not package or not version:
        return None
    return package, version.strip()


def analyse(archive_path: Path, lock: lock_closure.Lock,
            pip_version: str) -> tuple[list[str], dict[str, int]]:
    """Return (violations, counts). The counts feed the PASS verdict line."""
    violations: list[str] = list(lock.violations)
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        for document in ROOT_DOCUMENTS:
            if document not in names:
                violations.append(
                    f"the archive has no {document} at its root")
        if "bin/python3" not in names:
            violations.append("the archive has no bundled interpreter "
                              "(bin/python3)")
        directories = _dist_info_dirs(names)
        observed: dict[str, list[tuple[str, str]]] = {}
        for directory, files in sorted(directories.items()):
            if "METADATA" not in files:
                violations.append(
                    f"{directory}: no METADATA to identify the distribution")
                continue
            if "RECORD" not in files:
                violations.append(f"{directory}: no RECORD in the dist-info")
            identity = _metadata(archive, directory)
            if identity is None:
                violations.append(
                    f"{directory}: METADATA has no Name/Version")
                continue
            package, version = identity
            key = lock_closure.canonical(package)
            observed.setdefault(key, []).append((directory, version))
            # Wheel installs preserve the distribution's own case and spelling
            # inside the directory name (`PyYAML-6.0.2.dist-info`), so the
            # comparison is the PEP 503 name plus the version, not a string.
            base = directory[:-len(".dist-info")]
            dirname, _, dirversion = base.rpartition("-")
            if (not dirname or lock_closure.canonical(dirname) != key
                    or dirversion != version):
                violations.append(
                    f"{directory}: directory does not match its METADATA "
                    f"({package} {version})")
    counts = {
        "entries": len(names),
        "package_files": sum(1 for name in names
                             if name.startswith("retouch_ai_worker/")),
        "licences": sum(1 for name in names if LICENCE.match(name)),
        "distinfos": len(directories),
    }
    if counts["package_files"] == 0:
        violations.append("the archive carries no retouch_ai_worker package")
    if counts["licences"] == 0:
        violations.append("no licence file survived into the archive")

    allowances = {PIP}
    for key, entries in sorted(observed.items()):
        if len(entries) > 1:
            violations.append(
                f"{key}: carried by more than one dist-info directory "
                f"({', '.join(directory for directory, _ in entries)})")
    for key in sorted(set(observed) - set(lock.pins) - allowances):
        violations.append(
            f"{key}: the archive carries it, the lock does not pin it")
    for key in sorted(set(lock.pins) - set(observed)):
        violations.append(
            f"{key}: the lock pins it, the archive does not carry it")
    for key in sorted(set(observed) & set(lock.pins)):
        for directory, version in observed[key]:
            if version != lock.pins[key]:
                violations.append(
                    f"{directory}: METADATA says {version}, the lock pins "
                    f"{lock.pins[key]}")
    if PIP in observed:
        for directory, version in observed[PIP]:
            if version != pip_version:
                violations.append(
                    f"{directory}: the pip allowance is {version}, the "
                    f"environment's pip is {pip_version}")
    else:
        violations.append(
            "the archive carries no pip dist-info, so the one documented "
            "allowance cannot be verified")
    return violations, counts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--lock", type=Path,
                        default=WORKER_ROOT / "requirements.lock")
    parser.add_argument("--pip-version", required=True,
                        help="the version reported by the interpreter that "
                             "built the environment")
    args = parser.parse_args(argv)

    lock = lock_closure.read_lock(args.lock)
    violations, counts = analyse(args.archive, lock, args.pip_version)
    print(f"entries: {counts['entries']} "
          f"(worker package files: {counts['package_files']})")
    print(f"dist-info directories: {counts['distinfos']} "
          f"(the lock pins {len(lock.pins)})")
    print(f"licence files inside dist-info: {counts['licences']}")
    for violation in violations:
        print(f"  ✗ {violation}", file=sys.stderr)
    if violations:
        print(f"WORKER PAYLOAD: FAIL ({len(violations)} problem(s))",
              file=sys.stderr)
        return 1
    print(f"WORKER PAYLOAD: PASS ({counts['distinfos']} dist-info for "
          f"{len(lock.pins)} pins, {counts['licences']} licence files, "
          f"{counts['entries']} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
