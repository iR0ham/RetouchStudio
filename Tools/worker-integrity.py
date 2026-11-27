#!/usr/bin/env python3
"""Write or verify the bundled worker's deterministic integrity manifest.

The manifest covers every file, directory and symlink below Worker except the
manifest itself. File content, executable bits and symlink targets are sealed;
an added, removed, replaced or retargeted entry fails verification.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys

SCHEMA = "retouchstudio.worker-manifest/1"
MANIFEST = ".integrity.json"


class IntegrityError(Exception):
    pass


def digest(path: Path) -> str:
    """Hash the regular file opened without following a final symlink."""
    hasher = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise IntegrityError(f"Worker file is not regular: {path}")
        while chunk := os.read(descriptor, 4 << 20):
            hasher.update(chunk)
    finally:
        os.close(descriptor)
    return hasher.hexdigest()


def inventory(root: Path) -> list[dict[str, object]]:
    if root.is_symlink():
        raise IntegrityError("worker runtime root must not be a symbolic link")
    try:
        resolved_root = root.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise IntegrityError(f"worker runtime root cannot be resolved: {error}") from error

    def symlink_record(path: Path, relative: str) -> dict[str, object]:
        target = os.readlink(path)
        # Absolute links may point inside this build, but they break as soon as
        # the .app is moved. Relative links are allowed only when their resolved
        # target remains inside the sealed Worker tree.
        if os.path.isabs(target):
            raise IntegrityError(f"worker symlink must be relative: {relative}")
        try:
            path.resolve(strict=False).relative_to(resolved_root)
        except ValueError as error:
            raise IntegrityError(
                f"worker symlink escapes the runtime root: {relative}"
            ) from error
        except (OSError, RuntimeError) as error:
            raise IntegrityError(
                f"worker symlink cannot be resolved: {relative}"
            ) from error
        return {"path": relative, "kind": "symlink", "target": target}

    records: list[dict[str, object]] = []
    manifest_path = root / MANIFEST
    for base, directories, files in os.walk(root, followlinks=False):
        base_path = Path(base)
        directories.sort()
        files.sort()
        for name in list(directories):
            path = base_path / name
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                records.append(symlink_record(path, relative))
                directories.remove(name)
            elif stat.S_ISDIR(mode):
                records.append({
                    "path": relative,
                    "kind": "directory",
                    "mode": stat.S_IMODE(mode),
                })
            else:
                raise IntegrityError(f"unsupported Worker entry: {relative!r}")
        for name in files:
            path = base_path / name
            if path == manifest_path:
                continue
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                records.append(symlink_record(path, relative))
            elif stat.S_ISREG(mode):
                records.append({
                    "path": relative,
                    "kind": "file",
                    "mode": stat.S_IMODE(mode),
                    "sha256": digest(path),
                })
            else:
                raise IntegrityError(f"unsupported Worker entry: {relative!r}")
    records.sort(key=lambda record: record["path"])
    return records


def write(root: Path) -> None:
    if not root.is_dir():
        raise IntegrityError(f"Worker directory is missing: {root}")
    payload = {
        "schema": SCHEMA,
        "entries": inventory(root),
    }
    temporary = root / (MANIFEST + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.chmod(temporary, 0o644)
    os.replace(temporary, root / MANIFEST)
    print(f"worker integrity manifest: {len(payload['entries'])} entries")


def validate_entries(expected: object) -> list[dict[str, object]]:
    if not isinstance(expected, list):
        raise IntegrityError("worker integrity manifest has no entry list")

    seen: set[str] = set()
    fields = {
        "directory": {"path", "kind", "mode"},
        "file": {"path", "kind", "mode", "sha256"},
        "symlink": {"path", "kind", "target"},
    }
    for index, entry in enumerate(expected):
        if not isinstance(entry, dict):
            raise IntegrityError(f"worker integrity manifest has a malformed entry at index {index}")
        path = entry.get("path")
        if (
            not isinstance(path, str)
            or not path
            or "\0" in path
            or any(part in ("", ".", "..") for part in path.split("/"))
        ):
            raise IntegrityError(f"worker integrity manifest has a malformed entry at index {index}")
        if path in seen:
            raise IntegrityError(f"worker integrity manifest has a malformed entry at index {index}: duplicate path")
        seen.add(path)

        kind = entry.get("kind")
        if not isinstance(kind, str) or kind not in fields or set(entry) != fields[kind]:
            raise IntegrityError(f"worker integrity manifest has a malformed entry at index {index}")
        if kind in ("directory", "file"):
            mode = entry.get("mode")
            if type(mode) is not int or not 0 <= mode <= 0o7777:
                raise IntegrityError(f"worker integrity manifest has a malformed entry at index {index}")
        if kind == "file":
            checksum = entry.get("sha256")
            if (
                not isinstance(checksum, str)
                or len(checksum) != 64
                or any(character not in "0123456789abcdef" for character in checksum)
            ):
                raise IntegrityError(f"worker integrity manifest has a malformed entry at index {index}")
        if kind == "symlink" and (
            not isinstance(entry.get("target"), str) or not entry["target"]
        ):
            raise IntegrityError(f"worker integrity manifest has a malformed entry at index {index}")
    return expected


def verify(root: Path) -> None:
    manifest_path = root / MANIFEST
    try:
        manifest_stat = manifest_path.lstat()
    except FileNotFoundError as error:
        raise IntegrityError("worker integrity manifest is missing") from error
    if not stat.S_ISREG(manifest_stat.st_mode):
        raise IntegrityError("worker integrity manifest must be a regular non-symlink file")
    try:
        descriptor = os.open(
            manifest_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
        )
    except OSError as error:
        raise IntegrityError("worker integrity manifest cannot be opened safely") from error
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise IntegrityError("worker integrity manifest must be a regular non-symlink file")
        chunks = []
        while chunk := os.read(descriptor, 1 << 20):
            chunks.append(chunk)
        payload = json.loads(b"".join(chunks).decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise IntegrityError("worker integrity manifest is not valid JSON") from error
    finally:
        os.close(descriptor)
    if not isinstance(payload, dict) or payload.get("schema") != SCHEMA:
        raise IntegrityError("worker integrity manifest has an unknown schema")
    expected = validate_entries(payload.get("entries"))
    actual = inventory(root)
    if actual != expected:
        expected_by_path = {entry["path"]: entry for entry in expected}
        actual_by_path = {entry["path"]: entry for entry in actual}
        differences = sorted(
            (set(expected_by_path) | set(actual_by_path))
            - {path for path in expected_by_path if expected_by_path[path] == actual_by_path.get(path)}
        )
        preview = ", ".join(repr(path) for path in differences[:8])
        raise IntegrityError(f"worker integrity manifest mismatch: {preview}")
    print(f"worker integrity verified: {len(actual)} entries")


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("write", "verify"):
        print("usage: worker-integrity.py write|verify <Worker>", file=sys.stderr)
        return 2
    root = Path(sys.argv[2]).absolute()
    try:
        if sys.argv[1] == "write":
            write(root)
        else:
            verify(root)
    except (IntegrityError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
