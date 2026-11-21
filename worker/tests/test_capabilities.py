import importlib.util
import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from retouch_ai_worker import catalog as catalog_module
from retouch_ai_worker.capabilities import (BLOCKED, CAPABILITIES, PROVIDER,
                                            REQUIRES_MODEL, SUPPORTED, VOCABULARY,
                                            load_evidence, record, report)
from retouch_ai_worker.catalog import Catalog
from retouch_ai_worker.protocol import CATALOG_INVALID, WorkerError

PLATFORM = "macos-arm64"
MIGAN = "migan"
SWIN = "swin2sr-x4"
SAM = "sam2.1-hiera-tiny"
SAM_BYTES = 156_008_466


def _sparse(path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        handle.truncate(size)


def _versioned(root: Path, model: str, version: str, files: dict[str, int]) -> None:
    target = root / model / version
    for name, size in files.items():
        _sparse(target / name, size)
    (root / model / "active.json").write_text(json.dumps({
        "schema": "retouchstudio.model-active/1",
        "modelId": model,
        "version": version,
    }), encoding="utf-8")


class CapabilityReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "models"
        self.catalog = Catalog(self.root, allow_uncleared=False)

    def tearDown(self):
        self.tmp.cleanup()

    def by_id(self, evidence=(), importable=lambda name: True):
        # `importable` defaults to "everything is importable" so a test about
        # the model branch is not decided by this machine's site-packages. A
        # test that wants the runtime-package gate passes its own predicate.
        return {item["capabilityId"]: item
                for item in report(self.catalog, evidence=evidence,
                                   platform_name=PLATFORM,
                                   importable=importable)["capabilities"]}

    def test_every_frozen_capability_is_reported_once_with_a_reason(self):
        records = self.by_id()
        self.assertEqual(list(records), [spec.id for spec in CAPABILITIES])
        self.assertEqual(len(records), len(CAPABILITIES))
        for item in records.values():
            if item["state"] != SUPPORTED:
                self.assertTrue(item["reason"], item)
            else:
                self.assertTrue(item["evidence"], item)
        self.assertEqual(report(self.catalog, evidence=())["vocabulary"], VOCABULARY)

    def test_a_missing_model_is_requires_model(self):
        upscale = self.by_id()["upscale.4x"]
        self.assertEqual(upscale["state"], "requires_model")
        self.assertEqual(upscale["modelId"], SWIN)
        self.assertIn("not installed", upscale["reason"])

    def test_installed_without_evidence_is_blocked(self):
        _versioned(self.root, MIGAN, "1.0.0",
                   {"migan_pipeline_v2.onnx": 28_079_181})
        spot = self.by_id()["inpaint.spot"]
        self.assertEqual(spot["state"], "blocked")
        self.assertEqual(spot["modelVersion"], "1.0.0")
        self.assertIn("no recorded run", spot["reason"])

    def test_matching_evidence_makes_it_supported(self):
        _versioned(self.root, MIGAN, "1.0.0",
                   {"migan_pipeline_v2.onnx": 28_079_181})
        evidence = ({"capabilityId": "inpaint.spot", "platform": PLATFORM,
                     "provider": PROVIDER, "modelId": MIGAN,
                     "modelVersion": "1.0.0", "evidence": "fixture run"},)
        spot = self.by_id(evidence)["inpaint.spot"]
        self.assertEqual(spot["state"], "supported")
        self.assertEqual(spot["evidence"], "fixture run")

    def test_evidence_for_another_platform_does_not_count(self):
        _versioned(self.root, MIGAN, "1.0.0",
                   {"migan_pipeline_v2.onnx": 28_079_181})
        evidence = ({"capabilityId": "inpaint.spot", "platform": "macos-x64",
                     "provider": PROVIDER, "modelId": MIGAN,
                     "modelVersion": "1.0.0", "evidence": "fixture run"},)
        self.assertEqual(self.by_id(evidence)["inpaint.spot"]["state"], "blocked")

    def test_legacy_flat_install_is_blocked_until_adopted(self):
        _sparse(self.root / MIGAN / "migan_pipeline_v2.onnx", 28_079_181)
        spot = self.by_id()["inpaint.spot"]
        self.assertEqual(spot["state"], "blocked")
        self.assertIn("adopt", spot["reason"])

    def test_truncated_file_is_blocked_not_supported(self):
        _versioned(self.root, MIGAN, "1.0.0", {"migan_pipeline_v2.onnx": 3})
        evidence = ({"capabilityId": "inpaint.spot", "platform": PLATFORM,
                     "provider": PROVIDER, "modelId": MIGAN,
                     "modelVersion": "1.0.0", "evidence": "fixture run"},)
        spot = self.by_id(evidence)["inpaint.spot"]
        self.assertEqual(spot["state"], "blocked")
        self.assertIn("size check", spot["reason"])

    def test_a_sam_install_is_now_the_adoption_case_not_the_dr5_one(self):
        # SAM 2.1 tiny's file gained a recorded size and digest on 2026-11-18,
        # so the reporter can see what these bytes are and says what would make
        # them bindable. Before that it had nothing to say beyond DR-5.
        _sparse(self.root / "sam2.1-hiera-tiny" / "sam2.1_hiera_tiny.pt", 16)
        click = self.by_id()["mask.click"]
        self.assertEqual(click["state"], "blocked")
        self.assertIn("adopt", click["reason"])

    def test_weights_with_no_importable_runtime_are_blocked_before_the_model(self):
        # The checkpoint is installed at a recorded version and a recorded run
        # binds it: every condition DR-4 asks of the model is met. What is
        # missing is the package that reads it, and that is asked first because
        # no download the model manager offers can answer it.
        _versioned(self.root, SAM, "1.0.0", {"sam2.1_hiera_tiny.pt": SAM_BYTES})
        evidence = ({"capabilityId": "mask.click", "platform": PLATFORM,
                     "provider": PROVIDER, "modelId": SAM,
                     "modelVersion": "1.0.0", "evidence": "fixture run"},)
        self.assertEqual(self.by_id(evidence)["mask.click"]["state"], SUPPORTED)
        click = self.by_id(
            evidence, importable=lambda name: name != "sam2")["mask.click"]
        self.assertEqual(click["state"], "blocked")
        self.assertIn("cannot import sam2", click["reason"])
        self.assertEqual(click["modelId"], SAM)

    def test_the_ungated_report_answers_for_this_interpreter(self):
        # Nothing injected, so this is what a running worker really says. The
        # answer has to track the interpreter: a runtime that gains sam2 gains
        # the model branch back without anyone editing a test.
        present = importlib.util.find_spec("sam2") is not None
        click = self.by_id(importable=None)["mask.click"]
        self.assertEqual("cannot import sam2" in click.get("reason", ""),
                         not present)
        if not present:
            self.assertEqual(click["state"], "blocked")

    def test_an_unrecorded_entry_is_still_blocked_by_dr5(self):
        # No shipped entry is unrecorded any more, so DR-5's branch is shown
        # with the digests taken back out of one entry. The wrong-length stub
        # proves the rule fires before any byte is compared.
        unrecorded = tuple(
            replace(entry, files=tuple(replace(spec, sha256=None, bytes=None)
                                        for spec in entry.files))
            if entry.id == "sam2.1-hiera-tiny" else entry
            for entry in catalog_module.CATALOG)
        _sparse(self.root / "sam2.1-hiera-tiny" / "sam2.1_hiera_tiny.pt", 16)
        with patch("retouch_ai_worker.catalog.CATALOG", unrecorded):
            click = self.by_id()["mask.click"]
        self.assertEqual(click["state"], "blocked")
        self.assertIn("DR-5", click["reason"])

    def test_a_capability_never_binds_bytes_the_worker_cannot_verify(self):
        # The reporting layer and the load layer used to disagree: `_inspect`
        # called a pinless entry unverifiable while `require_verified` loaded it.
        # Both answers now come from the same admission rule, so an unavailable
        # optional model stays distinguishable from a trusted one — a bad pin can
        # never reach `supported`, whatever the evidence ledger claims.
        for defect in ("sha256", "bytes"):
            with self.subTest(pin=defect):
                broken = tuple(
                    replace(entry, files=tuple(
                        replace(spec, **({defect: None})) for spec in entry.files))
                    if entry.id == SWIN else entry
                    for entry in catalog_module.CATALOG)
                _versioned(self.root, SWIN, "1.0.0", {
                    "config.json": 772,
                    "preprocessor_config.json": 152,
                    "pytorch_model.bin": 48_460_141,
                })
                evidence = ({"capabilityId": "upscale.4x", "platform": PLATFORM,
                             "provider": PROVIDER, "modelId": SWIN,
                             "modelVersion": "1.0.0", "evidence": "a recorded run"},)
                with patch("retouch_ai_worker.catalog.CATALOG", broken):
                    upscale = self.by_id(evidence=evidence)["upscale.4x"]
                    catalog = Catalog(self.root, allow_uncleared=False)
                    with self.assertRaises(WorkerError) as caught:
                        catalog.require_verified(SWIN)
                self.assertEqual(upscale["state"], BLOCKED)
                self.assertNotEqual(upscale["state"], SUPPORTED)
                self.assertEqual(caught.exception.code, CATALOG_INVALID)
                self.assertEqual(caught.exception.data["reason"],
                                 "missing-digest" if defect == "sha256"
                                 else "missing-size")

    def test_an_uppercase_pin_does_not_block_a_capability(self):
        # Case is not a trust question. Normalising it here keeps a correctly
        # pinned model reportable, which the old string comparison could not.
        upper = tuple(
            replace(entry, files=tuple(replace(spec, sha256=spec.sha256.upper())
                                        for spec in entry.files))
            if entry.id == SWIN else entry
            for entry in catalog_module.CATALOG)
        _versioned(self.root, SWIN, "1.0.0", {
            "config.json": 772,
            "preprocessor_config.json": 152,
            "pytorch_model.bin": 48_460_141,
        })
        with patch("retouch_ai_worker.catalog.CATALOG", upper):
            record = self.by_id()["upscale.4x"]
        self.assertEqual(record["state"], BLOCKED)
        self.assertIn("no recorded run", record["reason"])

    def test_an_uninstalled_optional_model_is_still_reported_as_missing(self):
        # Legitimate optional-model behaviour, kept honest by the tightened
        # gates: nothing installed is `requires_model` (the UI offers a download),
        # which is a different answer from `blocked` (installed, not trustworthy).
        _sparse(self.root / "migan" / "migan_pipeline_v2.onnx", 3)
        records = self.by_id()
        self.assertEqual(records["inpaint.object"]["state"], REQUIRES_MODEL)
        self.assertEqual(records["upscale.4x"]["state"], REQUIRES_MODEL)

    def test_shipped_ledger_supports_only_the_recorded_upscale_run(self):
        entries = load_evidence()
        self.assertEqual([entry["capabilityId"] for entry in entries],
                         ["upscale.4x"])
        self.assertEqual(entries[0]["modelVersion"], "1.0.0")

    def test_missing_ledger_supports_nothing(self):
        _versioned(self.root, SWIN, "1.0.0", {
            "config.json": 772,
            "preprocessor_config.json": 152,
            "pytorch_model.bin": 48_460_141,
        })
        records = report(self.catalog, evidence=(), platform_name=PLATFORM)
        self.assertFalse(any(item["state"] == SUPPORTED
                             for item in records["capabilities"]))

    def test_record_returns_none_for_an_unknown_capability(self):
        self.assertIsNone(record("nope", self.catalog, evidence=()))


if __name__ == "__main__":
    unittest.main()
