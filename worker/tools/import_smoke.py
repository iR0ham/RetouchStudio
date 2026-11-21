"""Import the third-party modules the shipped worker loads lazily.

The protocol suite runs against `requirements-test.lock` (numpy and pillow),
so nothing in `Tests/run-worker.sh` ever imports torch, transformers, mlx,
mflux or onnxruntime. This script is the missing half: run it with a Python
that has the full `requirements.lock` installed and it proves those
distributions are importable together on this platform.

A fixed list alone is not enough: a newly pinned dependency added to the
worker tomorrow would not be in it, and the smoke would keep passing while
the new module went unexercised. So the list below is the critical-path
floor, and the set actually imported is that floor plus every third-party
top-level module the shipped package imports, derived with the same AST walk
`lock_closure.py` uses for the pin audit. A fixed target the code no longer
imports is reported as a failure — a stale entry is a promise nobody keeps —
and an import with no pin is named as `lock closure`'s failure rather than
silently skipped.

It is deliberately not part of the blocking suite. A real install of the
runtime lock is roughly 1.4 GB of site-packages, which is minutes of
download on every run, so the job that uses this script is allowed to fail
without blocking a merge.

The guarded `sam2` import is absent on purpose: its absence is a supported
state (mask.click reports itself blocked), not an installation failure. It is
also unpinned, so the plan names it instead of importing it.

Usage:
    <full-lock python> worker/tools/import_smoke.py \
        [--package worker/retouch_ai_worker] [--lock worker/requirements.lock]
"""
from __future__ import annotations

import argparse
import importlib
import sys
import time
from pathlib import Path
from typing import NamedTuple

WORKER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WORKER_ROOT / "tools"))
import lock_closure  # noqa: E402  (sibling tool; resolves after the insert)

# Mirrors the worker's own lazy import sites. Keep in step with engine.py:
#   :765        import torch                    (upscale tiling)
#   :884-885    import torch / Swin2SR...       (upscale weights)
#   :947        import onnxruntime as ort       (migan session)
#   :966-968    import mlx.core as mx, mflux... (flux2 edit)
# `numpy` and `PIL.Image` are unconditional in engine.py:21-22, which the
# protocol suite already exercises via the test lock; importing them here
# proves the full lock does not shadow them with a different build.
TARGETS = (
    ("torch", "upscale tiling"),
    ("transformers", "Swin2SR weights"),
    ("mlx.core", "flux device and cache limits"),
    ("mflux.models.common.config", "flux model config"),
    ("mflux.models.flux2.variants", "flux2 edit model"),
    ("onnxruntime", "migan session"),
    ("PIL.Image", "image decode and encode"),
    ("numpy", "array math"),
)


class Target(NamedTuple):
    module: str
    why: str
    derived: bool


class Plan:
    def __init__(self) -> None:
        self.targets: list[Target] = []
        self.stale: list[str] = []
        # (module, files, guard) for imports no lock entry provides. Not
        # imported here: an unguarded one is `lock_closure.py`'s failure, a
        # guarded one is a supported refusal and is named so the omission is
        # visible.
        self.unpinned: list[tuple[str, str, str]] = []
        # Every import is classified: stdlib and project-local names are not
        # third-party work, but they are counted so the verdict separates the
        # three kinds instead of collapsing them into "skipped".
        self.skipped_stdlib: list[str] = []
        self.skipped_local: list[str] = []

    @property
    def fixed(self) -> list[Target]:
        return [target for target in self.targets if not target.derived]

    @property
    def derived(self) -> list[Target]:
        return [target for target in self.targets if target.derived]


def _stdlib() -> frozenset[str]:
    try:
        return sys.stdlib_module_names
    except AttributeError:  # pragma: no cover - Python < 3.10
        return frozenset()


def plan(package: Path, lock: lock_closure.Lock,
         fixed: tuple[tuple[str, str], ...] = TARGETS) -> Plan:
    """Combine the fixed floor with the imports the code actually has."""
    imported = lock_closure.imported_modules(package)
    names: set[str] = set()
    for entry in imported.values():
        names |= entry.get("names", set())
    result = Plan()
    for module, why in fixed:
        if not any(name == module or name.startswith(module + ".")
                   for name in names):
            result.stale.append(module)
        result.targets.append(Target(module, why, False))
    fixed_modules = [module for module, _why in fixed]
    stdlib = _stdlib()
    for module in sorted(imported):
        if module in stdlib:
            result.skipped_stdlib.append(module)
            continue
        if module in lock_closure.FIRST_PARTY:
            result.skipped_local.append(module)
            continue
        # A fixed submodule already imports its parent package.
        if any(module == name or name.startswith(module + ".")
               for name in fixed_modules):
            continue
        distribution = lock_closure.ALIASES.get(
            module, lock_closure.canonical(module))
        if lock_closure.canonical(distribution) not in lock.pins:
            files = ", ".join(sorted(imported[module]["files"])[:2])
            entry = imported[module]
            guard = (", ".join(sorted(entry["guards"]))
                     if entry["guarded"] == {True} else "")
            result.unpinned.append((module, files, guard))
            continue
        files = ", ".join(sorted(imported[module]["files"])[:2])
        result.targets.append(
            Target(module, f"imported by {files}", True))
    return result


def run(targets: list[Target], importer=importlib.import_module
        ) -> tuple[list[str], float]:
    """Import every target. Returns (failures, seconds spent importing)."""
    failures: list[str] = []
    total = 0.0
    for target in targets:
        started = time.perf_counter()
        try:
            importer(target.module)
        except Exception as error:  # a broken install, not a refusal path
            failures.append(f"{target.module} ({target.why}): {error!r}")
            print(f"  ✗ {target.module}: {error!r}")
            continue
        elapsed = time.perf_counter() - started
        total += elapsed
        print(f"  · {target.module} imported in {elapsed:.2f}s "
              f"({target.why})")
    return failures, total


def main(argv: list[str] | None = None, importer=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--package", type=Path,
                        default=WORKER_ROOT / "retouch_ai_worker")
    parser.add_argument("--lock", type=Path,
                        default=WORKER_ROOT / "requirements.lock")
    args = parser.parse_args(argv)

    lock = lock_closure.read_lock(args.lock)
    result = plan(args.package, lock)
    for module, files, guard in result.unpinned:
        if guard:
            print(f"  ! {module}: imported by {files}, no distribution in "
                  f"{args.lock.name} provides it, and it is {guard} — a "
                  f"supported refusal, not imported", file=sys.stderr)
        else:
            print(f"  ! {module}: imported by {files} with no distribution in "
                  f"{args.lock.name} and no import guard; it is not imported "
                  f"here — the lock closure check must fail it",
                  file=sys.stderr)
    failures, total = run(result.targets, importer or importlib.import_module)
    problems = list(failures)
    for module in result.stale:
        problems.append(
            f"{module}: no longer imported by the worker; remove the stale "
            f"target")
        print(f"  ✗ {module}: no longer imported by the worker; remove the "
              f"stale target", file=sys.stderr)
    if problems:
        print(f"WORKER IMPORT SMOKE: FAIL ({len(problems)} problem(s))",
              file=sys.stderr)
        return 1
    print(f"WORKER IMPORT SMOKE: PASS ({len(result.targets)} third-party "
          f"modules: {len(result.fixed)} fixed + {len(result.derived)} "
          f"derived, {total:.1f}s of imports; skipped "
          f"{len(result.skipped_stdlib)} stdlib, "
          f"{len(result.skipped_local)} project-local, "
          f"{len(result.unpinned)} unpinned named above)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
