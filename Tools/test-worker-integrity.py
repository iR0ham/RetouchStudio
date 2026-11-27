#!/usr/bin/env python3
"""Focused regressions for the sealed Worker manifest verifier."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "worker_integrity", Path(__file__).with_name("worker-integrity.py")
)
assert SPEC is not None and SPEC.loader is not None
integrity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(integrity)


class WorkerIntegrityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="worker-integrity-test-")
        self.base = Path(self.temporary.name)
        self.root = self.base / "Worker"
        self.root.mkdir()
        (self.root / "worker.py").write_bytes(b"print('worker')\n")
        (self.root / "nested").mkdir()
        (self.root / "nested" / "data.bin").write_bytes(bytes(range(32)))
        integrity.write(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_regular_manifest_verifies_the_complete_sealed_tree(self) -> None:
        integrity.verify(self.root)
        (self.root / "unsealed.txt").write_text("added after sealing", encoding="utf-8")
        with self.assertRaises(integrity.IntegrityError):
            integrity.verify(self.root)

    def test_absolute_external_manifest_symlink_is_refused(self) -> None:
        manifest = self.root / integrity.MANIFEST
        external = self.base / "external-manifest.json"
        external.write_bytes(manifest.read_bytes())
        manifest.unlink()
        manifest.symlink_to(external)
        with self.assertRaises(integrity.IntegrityError):
            integrity.verify(self.root)

    def test_relative_external_manifest_symlink_is_refused(self) -> None:
        manifest = self.root / integrity.MANIFEST
        external = self.base / "external-manifest.json"
        external.write_bytes(manifest.read_bytes())
        manifest.unlink()
        manifest.symlink_to("../external-manifest.json")
        with self.assertRaises(integrity.IntegrityError):
            integrity.verify(self.root)

    def test_external_symlink_in_the_sealed_tree_is_refused(self) -> None:
        external = self.base / "outside.txt"
        external.write_text("outside", encoding="utf-8")
        (self.root / "escape.txt").symlink_to("../outside.txt")
        with self.assertRaises(integrity.IntegrityError):
            integrity.verify(self.root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
