#!/usr/bin/env python3
"""Make the bundled helper runtime independent of Homebrew.

Most wheels use @rpath or @loader_path. A handful of CPython's extension
modules (ssl, lzma, sqlite3, decimal) were linked against Homebrew dylibs by
absolute path. Each such dylib is copied into Worker/lib and every reference is
rewritten to a relative one, recursively, so the bundle keeps working on a Mac
with no Homebrew installation.

Usage: relink.py <Worker directory>
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

PREFIX = "/opt/homebrew"


def macho(path: str) -> bool:
    return b"Mach-O" in subprocess.run(["file", path], capture_output=True).stdout


def binaries(root: str):
    for base, _dirs, files in os.walk(root):
        for name in files:
            path = os.path.join(base, name)
            if not os.path.isfile(path):
                continue
            if name.endswith((".so", ".dylib")) or os.access(path, os.X_OK):
                if macho(path):
                    yield path


def dependencies(path: str) -> list[str]:
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout
    deps = []
    for line in out.splitlines()[1:]:
        if not line.strip():
            continue
        deps.append(line.split("(")[0].strip())
    return deps


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: relink.py <Worker directory>", file=sys.stderr)
        return 2
    root = sys.argv[1]
    lib_dir = os.path.join(root, "lib")
    os.makedirs(lib_dir, exist_ok=True)

    queue = list(binaries(root))
    seen: set[str] = set()
    rewritten = 0
    while queue:
        path = queue.pop(0)
        if path in seen:
            continue
        seen.add(path)
        for dep in dependencies(path):
            if not dep.startswith(PREFIX):
                continue
            target = os.path.join(lib_dir, os.path.basename(dep))
            if not os.path.exists(target):
                shutil.copy2(os.path.realpath(dep), target)
                queue.append(target)
            relative = os.path.relpath(target, os.path.dirname(path))
            if subprocess.run(["install_name_tool", "-change", dep,
                               "@loader_path/" + relative, path]).returncode != 0:
                print(f"could not rewrite {dep} in {path}", file=sys.stderr)
                return 1
            rewritten += 1
    # IDs are never used to load anything here, but leaving an absolute
    # Homebrew id in the bundle looks like a dependency to any audit.
    for name in sorted(os.listdir(lib_dir)):
        if name.endswith(".dylib"):
            subprocess.run(["install_name_tool", "-id", "@rpath/" + name,
                            os.path.join(lib_dir, name)], check=True)
    print(f"  · relinked {rewritten} Homebrew reference(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
