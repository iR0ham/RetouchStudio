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
import sys
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
                         ["google.protobuf"])

        # The `from` form records the bare namespace too, and that is what a
        # `from x import y` statement really imports: `google`, then `protobuf`
        # out of it. It stays pinned either way — the namespace is not a second
        # distribution — and the target follows the recorded dotted name.
        write_package(self.package,
                      {"engine.py": "from google import protobuf\n"})
        result = smoke.plan(self.package, lock, fixed=())
        self.assertEqual(result.unpinned, [])
        self.assertEqual([target.module for target in result.targets],
                         ["google"])

    def test_the_upb_tree_of_the_pinned_protobuf_wheel_is_a_target(self):
        """`google._upb._message` is protobuf's own tree, so it is a target (F8).

        The mirror of the closure seed: with the real pinned lock, the smoke
        must plan `google` as a derived target for an import inside
        `google/_upb/` — never as an `unpinned` entry — and must still name the
        namespace unpinned outside the prefixes protobuf ships.
        """
        lock = lock_closure.read_lock(WORKER / "requirements.lock")
        self.assertIn("protobuf", lock.pins)

        write_package(self.package, {
            "engine.py": "import google._upb._message\n"})
        result = smoke.plan(self.package, lock, fixed=())
        self.assertEqual(result.unpinned, [])
        self.assertEqual([target.module for target in result.targets],
                         ["google._upb._message"])
        self.assertEqual([target.module for target in result.derived],
                         ["google._upb._message"],
                         "the fixed floor does not name google")
        self.assertIn("engine.py", result.derived[0].why)

        imported: list[str] = []
        failures, _seconds = smoke.run(result.targets, imported.append)
        self.assertEqual(imported, ["google._upb._message"])
        self.assertEqual(
            failures, [],
            "if protobuf is installed its own extension module must load; a "
            "real ImportError here is a lock defect, not a planning one")

        # The `from` form of the same shipped prefix is a target too.
        write_package(self.package,
                      {"engine.py": "from google._upb import _message\n"})
        result = smoke.plan(self.package, lock, fixed=())
        self.assertEqual(result.unpinned, [])
        self.assertEqual([target.module for target in result.targets],
                         ["google._upb"])

        # Outside every shipped prefix the namespace stays unpinned and is not
        # imported, so the broadened alias cannot smuggle a foreign tree in.
        write_package(self.package, {"engine.py": "import google.auth\n"})
        result = smoke.plan(self.package, lock, fixed=())
        unpinned = {module: (files, guard)
                    for module, files, guard in result.unpinned}
        self.assertIn("google", unpinned)
        self.assertEqual(unpinned["google"][1], "")
        self.assertNotIn("google", [t.module for t in result.targets])
        imported = []
        smoke.run(result.targets, imported.append)
        self.assertEqual(imported, [])

    def test_a_functional_import_is_derived_or_named_never_invisible(self):
        """The smoke shares the closure's AST walk, so it sees the same imports.

        A pinned module imported by call must become a derived target and be
        imported; an unpinned one must be named; and a name the walk cannot read
        must be named too, so an empty target list can never mean "nothing to
        check". The three escapes measured on the reviewer's probe — aliased
        `import_module`, the `name=` keyword, `builtins.__import__` — are each
        asserted against both gates here, because a hole in the shared walk is a
        hole in both.
        """
        write_package(self.package, {
            "engine.py": ("from importlib import import_module\n"
                          "import_module('numpy')\n"),
        })
        result = smoke.plan(self.package, self.lock, fixed=())
        self.assertEqual([target.module for target in result.derived], ["numpy"])
        self.assertEqual(result.stale, [])
        imported: list[str] = []
        smoke.run(result.targets, imported.append)
        self.assertIn("numpy", imported)

        write_package(self.package, {
            "engine.py": "__import__(name='cv2')\n"})
        result = smoke.plan(self.package, self.lock, fixed=())
        unpinned = {module for module, _files, _guard in result.unpinned}
        self.assertIn("cv2", unpinned)
        self.assertNotIn("cv2", [t.module for t in result.targets])

        write_package(self.package, {
            "engine.py": "import builtins\nbuiltins.__import__('cv2')\n"})
        result = smoke.plan(self.package, self.lock, fixed=())
        self.assertIn("cv2", {module for module, _f, _g in result.unpinned})

        # An unreadable name is reported by both gates rather than skipped.
        write_package(self.package, {
            "engine.py": "import importlib\nimportlib.import_module(which)\n"})
        result = smoke.plan(self.package, self.lock, fixed=())
        self.assertEqual(len(result.unpinned), 1, result.unpinned)
        module, files, guard = result.unpinned[0]
        self.assertIn("engine.py:", module)
        self.assertEqual((files, guard), ("dynamic import", ""))
        self.assertEqual(result.targets, [])
        violations, _resolved, _optional = lock_closure.audit(
            self.lock, self.package)
        self.assertEqual(len(violations), 1)
        self.assertIn("cannot read", violations[0])

    def test_a_newly_pinned_submodule_is_a_dotted_target(self):
        """The derived target is the recorded dotted name, not its top level.

        `lock_closure` keeps every full dotted name it sees so a reader can go
        deeper than the first component, but the planner used to build its target
        from the top-level key alone. A worker that newly did
        `import yaml.nodes` against a pinned `pyyaml` therefore produced the
        target `yaml`, and the submodule that breaks on someone's machine — the
        one whose own import statement fails — was never exercised here. The
        measured case: `import yaml.nodes` used to plan `['yaml']`.
        """
        write_package(self.package, {"engine.py": "import yaml.nodes\n"})
        result = smoke.plan(self.package, self.lock, fixed=())
        self.assertEqual([target.module for target in result.targets],
                         ["yaml.nodes"])
        self.assertEqual([target.module for target in result.derived],
                         ["yaml.nodes"])
        self.assertEqual(result.unpinned, [])
        self.assertEqual(result.stale, [])

        imported: list[str] = []
        failures, _seconds = smoke.run(result.targets, imported.append)
        self.assertEqual(imported, ["yaml.nodes"],
                         "the submodule itself must reach the importer")
        self.assertEqual(failures, [])

        # A `from` form records both the module and the attribute; only real
        # modules may be imported, and the deepest module is the point.
        write_package(self.package,
                      {"engine.py": "from yaml.nodes import ScalarNode\n"})
        result = smoke.plan(self.package, self.lock, fixed=())
        self.assertEqual([target.module for target in result.derived],
                         ["yaml.nodes"])

    def test_one_target_per_distribution_when_only_top_levels_are_imported(self):
        """Dotted derivation must not multiply targets for nothing.

        Two pinned packages imported at their top level yield two targets, not a
        target per recorded name: `numpy` also records `numpy.core.multiarray`
        style attribute names through other spellings, and importing a package
        runs its `__init__`, so a parent already covers its children. The fixed
        floor counts as coverage too — a recorded submodule inside an existing
        target adds no import.
        """
        write_package(self.package, {
            "engine.py": "import numpy\nimport yaml\n",
        })
        result = smoke.plan(self.package, self.lock, fixed=())
        self.assertEqual([target.module for target in result.targets],
                         ["numpy", "yaml"])

        write_lock(self.lock_path, {"pillow": "1.0"})
        lock = lock_closure.read_lock(self.lock_path)
        write_package(self.package, {
            "engine.py": "import PIL\nfrom PIL.Image import open as op\n",
        })
        result = smoke.plan(self.package, lock, fixed=(("PIL", "imaging"),))
        self.assertEqual([target.module for target in result.fixed], ["PIL"])
        self.assertEqual(result.derived, [],
                         "the fixed parent already imports PIL.Image")
        self.assertEqual(result.stale, [])

    def test_the_shipped_package_has_no_stale_targets(self):
        """The real TARGETS still describe the real worker."""
        real_lock = lock_closure.read_lock(WORKER / "requirements.lock")
        result = smoke.plan(WORKER / "retouch_ai_worker", real_lock)
        self.assertEqual(result.stale, [])
        self.assertEqual([module for module, _files, _guard in result.unpinned],
                         ["sam2"])
        # Every dotted name the shipped code imports is already inside a target,
        # so the derivation adds no import cost here. If a future import site
        # names a deeper submodule it becomes one more target — which is the
        # point — and this assertion documents that today's tree costs the same
        # to smoke before and after.
        imported, _dynamic = lock_closure.imported_modules(
            WORKER / "retouch_ai_worker")
        names: set[str] = set()
        for entry in imported.values():
            names |= entry["names"]
        modules = [target.module for target in result.targets]
        third_party = sorted(
            name for name in names
            if name.split(".")[0] not in sys.stdlib_module_names
            and name.split(".")[0] not in lock_closure.FIRST_PARTY
            and name.split(".")[0] not in {m for m, _f, _g in result.unpinned})
        uncovered = sorted(name for name in third_party
                           if not any(name == module
                                      or name.startswith(module + ".")
                                      or module.startswith(name + ".")
                                      for module in modules))
        self.assertEqual(uncovered, [],
                         "a recorded third-party import name reaches neither a "
                         "target nor the unpinned list")

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
