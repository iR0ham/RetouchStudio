"""The import smoke must cover what the worker imports, not just its floor.

A fixed list of eight modules could pass forever while a newly pinned import
went unexercised — the same shape of hole as the `cv2` import the lock
closure exists for. These tests seed the three interesting shapes: a pinned
module the fixed list does not name (it must be derived and imported), a
fixed target the code no longer imports (it must be reported), and an
unpinned import (it must stay visible and remain the lock closure's failure).
They need no torch, no download and no GPU: the planner reads source, and the
import step takes an injected importer.
"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

WORKER = Path(__file__).resolve().parents[1]
TOOL = WORKER / "tools" / "import_smoke.py"

_spec = importlib.util.spec_from_file_location("import_smoke", TOOL)
smoke = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(smoke)

lock_closure = smoke.lock_closure
HASH = "a" * 64


def write_lock(path: Path, pins: dict[str, str]) -> None:
    lines = []
    for name, version in pins.items():
        lines.append(f"{name}=={version} \\")
        lines.append(f"    --hash=sha256:{HASH}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_package(path: Path, files: dict[str, str]) -> None:
    path.mkdir(parents=True, exist_ok=True)
    for name, source in files.items():
        (path / name).write_text(source, encoding="utf-8")


class ImportSmokePlanTest(unittest.TestCase):
    def setUp(self):
        self._scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self._scratch.cleanup)
        self.root = Path(self._scratch.name)
        self.package = self.root / "pkg"
        self.lock_path = self.root / "requirements.lock"
        # yaml is a real alias (`pyyaml`); cv2 is real and unpinned; sam2 is
        # the shipped guarded refusal.
        write_lock(self.lock_path, {"numpy": "2.0", "pyyaml": "6.0"})
        self.lock = lock_closure.read_lock(self.lock_path)

    def test_a_new_pinned_import_is_derived_and_imported(self):
        """Seeded defect: an import the fixed floor does not name.

        `yaml` is pinned through the `pyyaml` alias and absent from the fixed
        list. The plan must add it and the runner must import it, so a future
        pinned dependency cannot hide behind an outdated TARGETS.
        """
        write_package(self.package, {
            "engine.py": ("import json\nimport numpy\nimport yaml\n"
                          "import retouch_ai_worker\n"),
        })
        fixed = (("numpy", "array math"),)
        result = smoke.plan(self.package, self.lock, fixed=fixed)
        self.assertEqual(result.stale, [])
        derived = [target for target in result.derived]
        self.assertEqual([target.module for target in derived], ["yaml"])
        self.assertIn("engine.py", derived[0].why)
        # The three kinds are separated, not collapsed: stdlib and the
        # project's own package are counted, third-party names are targets.
        self.assertEqual(result.skipped_stdlib, ["json"])
        self.assertEqual(result.skipped_local, ["retouch_ai_worker"])

        imported: list[str] = []
        failures, _seconds = smoke.run(result.targets, imported.append)
        self.assertEqual(failures, [])
        self.assertEqual(imported, ["numpy", "yaml"])

    def test_a_fixed_target_the_code_dropped_is_reported(self):
        """A stale entry is a promise nobody keeps; it must fail the smoke."""
        write_package(self.package, {
            "engine.py": "from PIL import Image\nimport numpy\n",
        })
        fixed = (("torch", "upscale tiling"),
                 ("PIL.Image", "image decode and encode"),
                 ("numpy", "array math"))
        result = smoke.plan(self.package, self.lock, fixed=fixed)
        self.assertEqual(result.stale, ["torch"],
                         "only the target the code no longer imports is stale")
        # The submodule target is present as the parent of the imported name.
        self.assertNotIn("PIL.Image", result.stale)

    def test_an_unpinned_import_stays_the_lock_closures_failure(self):
        """Seeded defect B1-like: `import cv2`, no pin.

        The smoke must not mask it: the module is named as unpinned, is not
        imported, and `lock_closure.audit` — the required gate — fails it. A
        guarded unpinned import (sam2) is named too, but stays optional.
        """
        write_package(self.package, {
            "engine.py": ("import cv2\n"
                          "try:\n"
                          "    import sam2\n"
                          "except ImportError:\n"
                          "    sam2 = None\n"),
        })
        result = smoke.plan(self.package, self.lock, fixed=())
        unpinned = {module: (files, guard)
                    for module, files, guard in result.unpinned}
        self.assertIn("cv2", unpinned)
        self.assertEqual(unpinned["cv2"][1], "",
                         "an unguarded import must not look optional")
        self.assertIn("ImportError", unpinned["sam2"][1])
        self.assertNotIn("cv2", [target.module for target in result.targets])
        self.assertNotIn("sam2", [target.module for target in result.targets])

        imported: list[str] = []
        smoke.run(result.targets, imported.append)
        self.assertEqual(imported, [], "the smoke must not stand in for the "
                                       "lock closure by importing it")

        violations, _resolved, optional = lock_closure.audit(
            self.lock, self.package)
        self.assertEqual(len(violations), 1)
        self.assertIn("cv2", violations[0])
        self.assertIn("sam2", optional)

    def test_a_namespace_import_outside_the_aliased_distribution_is_unpinned(self):
        """A shared namespace must not borrow the alias's pin.

        `google` maps to protobuf, but protobuf only owns `google.protobuf`.
        `google.cloud.storage` used to be planned as a pinned target and
        imported; it must be named as unpinned instead.
        """
        write_lock(self.lock_path, {"protobuf": "7.0"})
        lock = lock_closure.read_lock(self.lock_path)
        write_package(self.package, {
            "engine.py": "import google.cloud.storage\n"})
        result = smoke.plan(self.package, lock, fixed=())
        unpinned = {module: (files, guard)
                    for module, files, guard in result.unpinned}
        self.assertIn("google", unpinned)
        self.assertEqual(unpinned["google"][1], "")
        self.assertNotIn("google", [target.module for target in result.targets])
        imported: list[str] = []
        smoke.run(result.targets, imported.append)
        self.assertEqual(imported, [], "an unpinned namespace is not imported")

        write_package(self.package, {"engine.py": "import google.protobuf\n"})
        result = smoke.plan(self.package, lock, fixed=())
        self.assertEqual(result.unpinned, [])
        self.assertEqual([target.module for target in result.targets],
                         ["google"])

    def test_the_shipped_package_has_no_stale_targets(self):
        """The real TARGETS still describe the real worker."""
        real_lock = lock_closure.read_lock(WORKER / "requirements.lock")
        result = smoke.plan(WORKER / "retouch_ai_worker", real_lock)
        self.assertEqual(result.stale, [])
        self.assertEqual([module for module, _files, _guard in result.unpinned],
                         ["sam2"])

    def test_a_broken_import_is_a_failure(self):
        """Seeded defect E3: the module imports and the interpreter cannot load it."""
        write_package(self.package, {"engine.py": "import numpy\n"})

        def broken(name):
            raise ModuleNotFoundError(name)

        result = smoke.plan(self.package, self.lock,
                            fixed=(("numpy", "array math"),))
        failures, _seconds = smoke.run(result.targets, broken)
        self.assertEqual(len(failures), 1)
        self.assertIn("numpy", failures[0])


if __name__ == "__main__":
    unittest.main()
