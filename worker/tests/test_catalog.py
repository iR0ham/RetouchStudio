import fcntl
import hashlib
import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path

from unittest.mock import patch

from retouch_ai_worker import catalog as catalog_module
from retouch_ai_worker.catalog import (CATALOG, LEGACY_LEASE, Catalog, ModelEntry,
                                       ModelFile)
from retouch_ai_worker.protocol import (BUSY, CHECKSUM_MISMATCH, LICENSE_BLOCKED,
                                        MODEL_MISSING, UNKNOWN_MODEL, WorkerError)

# The catalog only ships models whose weights are cleared. The gate still has
# to refuse an uncleared entry if one is ever added, so the test supplies one.
UNCLEARED = ModelEntry(id="eval-only", name="Eval only", task="inpainting",
                       license_id="NOASSERTION", commercial_ok=False,
                       source="local", files=(ModelFile("weights.bin"),))

# A flat install that a test can adopt while a reader waits on the legacy lease.
LEGACY = ModelEntry(id="legacy-race", name="Legacy race", task="inpainting",
                    license_id="MIT", commercial_ok=True, source="local",
                    files=(ModelFile("weights.bin"),))

# A model small enough for a test to write whole, so its load path can be
# checked against a real digest instead of only a recorded size.
WEIGHTS = b"weights"
VERIFIED = ModelEntry(
    id="tiny-model", name="Tiny", task="upscaling", license_id="Apache-2.0",
    commercial_ok=True, source="local",
    files=(ModelFile("weights.bin", hashlib.sha256(WEIGHTS).hexdigest(),
                     len(WEIGHTS)),))
UNDIGESTED = ModelEntry(
    id="size-only", name="Size only", task="upscaling", license_id="Apache-2.0",
    commercial_ok=True, source="local", files=(ModelFile("weights.bin", None,
                                                         len(WEIGHTS)),))


class _FakeClock:
    """Advances only when the lease loop sleeps, so the 5 s wait is instant."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


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

    def test_truncated_install_is_refused_not_loaded(self):
        # capability.list already reports this install blocked; a submission
        # that names only the job kind must not load it anyway.
        version = self.root / "migan" / "1.0.0"
        version.mkdir(parents=True)
        (version / "migan_pipeline_v2.onnx").write_bytes(b"short")
        (self.root / "migan" / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": "migan",
            "version": "1.0.0",
        }), encoding="utf-8")
        catalog = Catalog(self.root, allow_uncleared=False)
        with self.assertRaises(WorkerError) as caught:
            catalog.require("migan")
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(caught.exception.data["model"], "migan")
        self.assertEqual(caught.exception.data["file"], "migan_pipeline_v2.onnx")
        self.assertEqual(caught.exception.data["expected_bytes"], 28_079_181)
        self.assertEqual(caught.exception.data["actual_bytes"], 5)
        # A refused model stays deletable: nothing may hold its lease.
        self.assertEqual(catalog._leases, {})

    def test_correct_size_install_still_resolves(self):
        version = self.root / "migan" / "1.0.0"
        version.mkdir(parents=True)
        with (version / "migan_pipeline_v2.onnx").open("wb") as handle:
            handle.truncate(28_079_181)
        (self.root / "migan" / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": "migan",
            "version": "1.0.0",
        }), encoding="utf-8")
        catalog = Catalog(self.root, allow_uncleared=False)
        self.assertEqual(catalog.require("migan"), version)

    def test_a_verified_load_returns_the_resolved_root(self):
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with patch("retouch_ai_worker.catalog.CATALOG", CATALOG + (VERIFIED,)):
            self.assertEqual(catalog.require_verified(VERIFIED.id), folder)
        self.assertEqual(len(catalog._leases), 1)

    def test_a_file_that_does_not_match_its_digest_is_refused(self):
        # Same length, different bytes: the size gate in `require` cannot see
        # this, which is what the load-time digest is for.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with patch("retouch_ai_worker.catalog.CATALOG", CATALOG + (VERIFIED,)):
            self.assertEqual(catalog.require_verified(VERIFIED.id), folder)
            (folder / "weights.bin").write_bytes(b"tampered")
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(caught.exception.data["file"], "weights.bin")
        # A model that failed its checksum stays deletable.
        self.assertEqual(catalog._leases, {})

    def test_an_entry_without_a_recorded_digest_loads_on_size(self):
        folder = self.root / UNDIGESTED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with patch("retouch_ai_worker.catalog.CATALOG", CATALOG + (UNDIGESTED,)):
            self.assertEqual(catalog.require_verified(UNDIGESTED.id), folder)

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

    def test_legacy_lease_timeout_is_busy_not_missing(self):
        flat = self.root / LEGACY.id
        flat.mkdir()
        (flat / "weights.bin").write_bytes(b"w")
        lock = self.root / ".locks" / f"{LEGACY.id}{LEGACY_LEASE}"
        lock.parent.mkdir(parents=True)
        fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        catalog = Catalog(self.root, allow_uncleared=False)
        try:
            with patch("retouch_ai_worker.catalog.CATALOG", CATALOG + (LEGACY,)), \
                 patch("retouch_ai_worker.catalog.time", _FakeClock()):
                with self.assertRaises(WorkerError) as caught:
                    catalog.require(LEGACY.id)
        finally:
            os.close(fd)
        # A lease holder is a busy resource: the model is installed, and the
        # caller can retry once the adoption or delete finishes.
        self.assertEqual(caught.exception.code, BUSY)
        self.assertEqual(caught.exception.data,
                         {"model": LEGACY.id, "reason": "leased"})

    def test_adoption_during_the_lease_wait_re_resolves(self):
        flat = self.root / LEGACY.id
        flat.mkdir()
        (flat / "weights.bin").write_bytes(b"w")
        version = flat / "1.0.0"
        lock = self.root / ".locks" / f"{LEGACY.id}{LEGACY_LEASE}"
        lock.parent.mkdir(parents=True)
        fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        started = threading.Event()

        def adopt():
            started.wait(5)
            # The reader has resolved the flat layout and is waiting on the
            # lease; now finish the adoption it is waiting for.
            time.sleep(0.2)
            version.mkdir()
            os.replace(flat / "weights.bin", version / "weights.bin")
            (flat / "active.json").write_text(json.dumps({
                "schema": "retouchstudio.model-active/1",
                "modelId": LEGACY.id,
                "version": "1.0.0",
            }), encoding="utf-8")
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

        thread = threading.Thread(target=adopt)
        thread.start()
        seen = []
        real_resolve = catalog_module.resolve_model_root

        def record(root, model_id):
            result = real_resolve(root, model_id)
            seen.append(result)
            return result

        catalog = Catalog(self.root, allow_uncleared=False)
        try:
            with patch("retouch_ai_worker.catalog.CATALOG", CATALOG + (LEGACY,)), \
                 patch("retouch_ai_worker.catalog.resolve_model_root", record):
                started.set()
                root = catalog.require(LEGACY.id)
        finally:
            thread.join(5)
            catalog.close()
        self.assertEqual(seen[0], flat, "the first resolution saw the flat layout")
        self.assertEqual(root, version,
                         "the worker used the version the pointer names, not the stale path")
        self.assertNotIn((LEGACY.id, LEGACY_LEASE), catalog._leases,
                         "the stale flat lease is released")

    def test_every_entry_has_a_license_id(self):
        for entry in CATALOG:
            self.assertTrue(entry.license_id, entry.id)
            if entry.commercial_ok:
                self.assertIn(entry.license_id, {"Apache-2.0", "MIT", "BSD-3-Clause"},
                              f"{entry.id} claims to be commercial")


if __name__ == "__main__":
    unittest.main()
