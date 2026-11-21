"""Import the heavy modules the shipped worker loads lazily.

The protocol suite runs against `requirements-test.lock` (numpy and pillow),
so nothing in `Tests/run-worker.sh` ever imports torch, transformers, mlx,
mflux or onnxruntime. This script is the missing half: run it with a Python
that has the full `requirements.lock` installed and it proves those
distributions are importable together on this platform.

It is deliberately not part of the blocking suite. A real install of the
runtime lock is roughly 1.4 GB of site-packages, which is minutes of
download on every run, so the job that uses this script is allowed to fail
without blocking a merge.

The guarded `sam2` import is absent on purpose: its absence is a supported
state (mask.click reports itself blocked), not an installation failure.

Usage:
    <full-lock python> worker/tools/import_smoke.py
"""
from __future__ import annotations

import importlib
import sys
import time

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


def main() -> int:
    failures: list[str] = []
    total = 0.0
    for module, why in TARGETS:
        started = time.perf_counter()
        try:
            importlib.import_module(module)
        except Exception as error:  # a broken install, not a refusal path
            failures.append(f"{module} ({why}): {error!r}")
            print(f"  ✗ {module}: {error!r}")
            continue
        elapsed = time.perf_counter() - started
        total += elapsed
        print(f"  · {module} imported in {elapsed:.2f}s ({why})")
    if failures:
        for failure in failures:
            print(f"  ✗ {failure}", file=sys.stderr)
        print(f"WORKER IMPORT SMOKE: FAIL ({len(failures)} module(s))",
              file=sys.stderr)
        return 1
    print(f"WORKER IMPORT SMOKE: PASS ({len(TARGETS)} modules, "
          f"{total:.1f}s of imports)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
