import importlib.util
import json
import os
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
        spot = self.by_id()["inpaint.spot"]
        self.assertEqual(spot["state"], "requires_model")
        self.assertEqual(spot["modelId"], MIGAN)
        self.assertIn("not installed", spot["reason"])

    def test_a_licence_admitted_model_is_offered_for_download(self):
        # swin2sr's weights are approved-with-conditions and every condition is
        # met (Docs/MODEL_LICENCES.md §11, decided 2026-11-22 under the
        # standing execution authority), so the licence gate no longer refuses
        # `upscale.4x` — the only AI capability
        # this product ships. Nothing is installed in this report, so the answer
        # is the honest download offer rather than `blocked`. The licence branch
        # itself stays pinned by `test_an_excluded_model_is_never_offered_*`.
        upscale = self.by_id()["upscale.4x"]
        self.assertEqual(upscale["state"], "requires_model")
        self.assertEqual(upscale["modelId"], SWIN)
        self.assertIn("not installed", upscale["reason"])
        self.assertNotIn("no established permission", upscale["reason"])

    def test_an_excluded_model_is_never_offered_for_download(self):
        # The licence refusal still wins over a download offer: `requires_model`
        # would tell the UI to fetch weights the catalogue refuses at install.
        # The shipping table admits every entry now, so the branch is shown by
        # replacing one entry's weights record with a refusal and keeping the
        # rest of the table intact.
        shipped = {entry.id: entry for entry in catalog_module.CATALOG}
        refused = replace(
            shipped[SWIN],
            permitted_use=replace(
                shipped[SWIN].permitted_use,
                weights=replace(
                    shipped[SWIN].permitted_use.weights,
                    verdict="excluded", can_acquire=False, can_redistribute=False,
                    can_use=False, conditions=(),
                    note="refused for this test")))
        patched = tuple(refused if entry.id == SWIN else entry
                        for entry in catalog_module.CATALOG)
        self.assertEqual([entry.id for entry in patched],
                         [entry.id for entry in catalog_module.CATALOG],
                         "the substitution keeps the table itself intact")
        with patch("retouch_ai_worker.catalog.CATALOG", patched):
            upscale = self.by_id()["upscale.4x"]
        self.assertEqual(upscale["state"], "blocked")
        self.assertEqual(upscale["modelId"], SWIN)
        self.assertIn("excluded", upscale["reason"])
        self.assertNotIn("not installed", upscale["reason"])

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

    def test_the_report_refuses_the_shapes_the_loader_refuses(self):
        # The other agreement test covers a bad *pin*. These are bad *installs*
        # that every recorded field still reads correct about: a listed weight
        # reached through a symlink (its size is read through the link, so the size
        # check passes) and a payload the catalog does not name (invisible to a pass
        # that only visits listed names). `_inspect` used to accept both and could
        # answer `supported` for an install `_check_sizes` refuses — the UI offering
        # a job the worker would reject at load.
        shipped = {entry.id: entry for entry in catalog_module.CATALOG}
        sizes = {spec.path: spec.bytes for spec in shipped[SWIN].files}
        evidence = ({"capabilityId": "upscale.4x", "platform": PLATFORM,
                     "provider": PROVIDER, "modelId": SWIN,
                     "modelVersion": "1.0.0", "evidence": "a recorded run"},)
        for defect in ("clean", "symlink", "unlisted"):
            with self.subTest(defect=defect):
                root = Path(self.tmp.name) / f"store-{defect}"
                _versioned(root, SWIN, "1.0.0", sizes)
                install = root / SWIN / "1.0.0"
                if defect == "symlink":
                    name = sorted(sizes)[-1]
                    _sparse(root / "outside.bin", sizes[name])
                    os.unlink(install / name)
                    os.symlink(root / "outside.bin", install / name)
                elif defect == "unlisted":
                    # The exact substitution the convention-following loaders allow:
                    # a `model.safetensors` nobody pinned, beside honest weights.
                    _sparse(install / "model.safetensors", 4_096)
                catalog = Catalog(root, allow_uncleared=False)
                item = {r["capabilityId"]: r for r in report(
                    catalog, evidence=evidence, platform_name=PLATFORM,
                    importable=lambda name: True)["capabilities"]}["upscale.4x"]
                loader_reason = None
                try:
                    # `require`, not `require_verified`: these fixtures carry the
                    # right *lengths* rather than the published bytes, so a digest
                    # pass would fail for an unrelated reason. Both shapes under
                    # test are caught by the size pass, which is the layer that used
                    # to disagree with this report.
                    catalog.require(SWIN)
                except WorkerError as error:
                    loader_reason = error.data.get("reason")
                if defect == "clean":
                    # Without this arm the test would pass on a fixture that never
                    # installed anything readable, whatever the code did.
                    self.assertIsNone(loader_reason, item)
                    self.assertEqual(item["state"], SUPPORTED)
                    continue
                self.assertEqual(item["state"], BLOCKED)
                self.assertIn("verify it in the model manager", item["reason"])
                self.assertEqual(
                    loader_reason,
                    "unsafe-path" if defect == "symlink" else "unlisted-file")

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
        # `inpaint.object` is deliberately absent from this list: it binds
        # `flux2-klein-4b-q4`, whose record refuses it, and the licence answer is
        # pinned by `test_the_flux_capabilities_are_blocked_on_licence_not_missing`.
        records = self.by_id()
        self.assertEqual(records["inpaint.spot"]["state"], REQUIRES_MODEL)
        self.assertEqual(records["upscale.4x"]["state"], REQUIRES_MODEL)

    def test_the_flux_capabilities_are_blocked_on_licence_not_missing(self):
        # S-FLUX, and the distinction this report exists to make. Nothing is
        # installed here either way, so the only reason `flux2-klein-4b-q4` could
        # produce a download offer is its record — and its record says UNKNOWN.
        # `requires_model` would tell the user a 4.6 GB transfer is the remedy for
        # a permission nobody has granted, which is the failure mode DR-15 names.
        records = self.by_id()
        for capability in ("generative.edit", "generative.reimagine", "inpaint.object"):
            with self.subTest(capability=capability):
                record = records[capability]
                self.assertEqual(record["state"], BLOCKED)
                self.assertIn("no established permission", record["reason"])
                self.assertIn("weights verdict: unknown", record["reason"])
                self.assertNotEqual(record["state"], REQUIRES_MODEL)
        # The refusal is ordered before the runtime-package probe and the install
        # check, so it does not depend on this interpreter or this disk: an entry
        # that is admitted answers differently with nothing installed.
        self.assertEqual(records["upscale.4x"]["state"], REQUIRES_MODEL)

    def test_shipped_ledger_supports_only_the_recorded_upscale_run(self):
        entries = load_evidence()
        self.assertEqual([entry["capabilityId"] for entry in entries],
                         ["upscale.4x"])
        self.assertEqual(entries[0]["modelVersion"], "1.0.0")

    def test_missing_ledger_supports_nothing(self):
        # Installed and importable with no recorded run. The licence now admits
        # this model without the evaluation switch (decided 2026-11-22),
        # so `allow_uncleared` is no longer what gets the report past the
        # licence gate — the missing ledger is.
        catalog = Catalog(self.root, allow_uncleared=True)
        _versioned(self.root, SWIN, "1.0.0", {
            "config.json": 772,
            "preprocessor_config.json": 152,
            "pytorch_model.bin": 48_460_141,
        })
        records = report(catalog, evidence=(), platform_name=PLATFORM)
        upscale = {item["capabilityId"]: item
                   for item in records["capabilities"]}["upscale.4x"]
        self.assertEqual(upscale["state"], "blocked")
        self.assertIn("no recorded run", upscale["reason"])
        self.assertFalse(any(item["state"] == SUPPORTED
                             for item in records["capabilities"]))

    def test_record_returns_none_for_an_unknown_capability(self):
        self.assertIsNone(record("nope", self.catalog, evidence=()))


if __name__ == "__main__":
    unittest.main()
