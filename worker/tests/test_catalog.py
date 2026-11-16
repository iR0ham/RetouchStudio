import tempfile
import unittest
from pathlib import Path

from unittest.mock import patch

from retouch_ai_worker.catalog import CATALOG, Catalog, ModelEntry, ModelFile
from retouch_ai_worker.protocol import (LICENSE_BLOCKED, MODEL_MISSING,
                                        UNKNOWN_MODEL, WorkerError)

# The catalog only ships models whose weights are cleared. The gate still has
# to refuse an uncleared entry if one is ever added, so the test supplies one.
UNCLEARED = ModelEntry(id="eval-only", name="Eval only", task="inpainting",
                       license_id="NOASSERTION", commercial_ok=False,
                       source="local", files=(ModelFile("weights.bin"),))


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())

    def test_flux_is_commercial_and_listed(self):
        catalog = Catalog(self.root, allow_uncleared=False)
        listed = {entry["id"]: entry for entry in catalog.list()}
        self.assertTrue(listed["flux2-klein-4b-q4"]["commercial_ok"])
        self.assertEqual(listed["flux2-klein-4b-q4"]["license"], "Apache-2.0")
        self.assertEqual(len(listed), len(CATALOG))

    def test_unlicensed_model_is_refused(self):
        catalog = Catalog(self.root, allow_uncleared=False)
        with patch("retouch_ai_worker.catalog.CATALOG", CATALOG + (UNCLEARED,)):
            with self.assertRaises(WorkerError) as caught:
                catalog.require("eval-only")
        self.assertEqual(caught.exception.code, LICENSE_BLOCKED)

    def test_eval_switch_allows_but_then_requires_files(self):
        catalog = Catalog(self.root, allow_uncleared=True)
        with patch("retouch_ai_worker.catalog.CATALOG", CATALOG + (UNCLEARED,)):
            with self.assertRaises(WorkerError) as caught:
                catalog.require("eval-only")
        self.assertEqual(caught.exception.code, MODEL_MISSING)

    def test_every_shipped_model_is_cleared(self):
        self.assertTrue(all(entry.commercial_ok for entry in CATALOG),
                        [entry.id for entry in CATALOG if not entry.commercial_ok])

    def test_missing_installed_model(self):
        catalog = Catalog(self.root, allow_uncleared=False)
        with self.assertRaises(WorkerError) as caught:
            catalog.require("flux2-klein-4b-q4")
        self.assertEqual(caught.exception.code, MODEL_MISSING)

    def test_installed_model_resolves(self):
        target = self.root / "sam2.1-hiera-tiny" / "sam2.1_hiera_tiny.pt"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"weights")
        catalog = Catalog(self.root, allow_uncleared=False)
        self.assertEqual(catalog.require("sam2.1-hiera-tiny"), target.parent)
        self.assertTrue(catalog.list()[1]["installed"])

    def test_unknown_model(self):
        with self.assertRaises(WorkerError) as caught:
            Catalog(self.root).get("nope")
        self.assertEqual(caught.exception.code, UNKNOWN_MODEL)

    def test_verify_detects_tampering(self):
        target = self.root / "flux2-klein-4b-q4" / "vae" / "0.safetensors"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"not the real weights")
        catalog = Catalog(self.root)
        report = catalog.verify("flux2-klein-4b-q4")
        self.assertFalse(report["ok"])
        self.assertTrue(any(item["reason"] == "checksum" for item in report["failed"]))

    def test_every_entry_has_a_license_id(self):
        for entry in CATALOG:
            self.assertTrue(entry.license_id, entry.id)
            if entry.commercial_ok:
                self.assertIn(entry.license_id, {"Apache-2.0", "MIT", "BSD-3-Clause"},
                              f"{entry.id} claims to be commercial")


if __name__ == "__main__":
    unittest.main()
