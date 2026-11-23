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
from retouch_ai_worker.catalog import (APPROVED, APPROVED_WITH_CONDITIONS, CATALOG,
                                       EXCLUDED, LEGACY_LEASE, LICENCE_READ_ON,
                                       REQUIRED_USE, STATED_BY_INFERRED,
                                       STATED_BY_NOT_ESTABLISHED,
                                       STATED_BY_RIGHTS_HOLDER, UNKNOWN,
                                       ArtefactTerms, Catalog, ModelEntry,
                                       ModelFile, PermittedUse, UseCondition)
from retouch_ai_worker.protocol import (BUSY, CHECKSUM_MISMATCH, LICENSE_BLOCKED,
                                        MODEL_MISSING, UNKNOWN_MODEL, WorkerError)


def terms(**overrides) -> ArtefactTerms:
    """A complete, admitted artefact record; overrides make the bad variants."""
    fields = dict(
        use=REQUIRED_USE, can_acquire=True, can_redistribute=True, can_use=True,
        stated_by=STATED_BY_RIGHTS_HOLDER, evidence_url="https://example.test/L",
        read_on=LICENCE_READ_ON, verdict=APPROVED)
    fields.update(overrides)
    return ArtefactTerms(**fields)


def use_class(**overrides) -> PermittedUse:
    record = dict(code=terms(), weights=terms(), training_data=terms())
    record.update(overrides)
    return PermittedUse(**record)


CLEARED_USE = use_class()
UNCLEARED_USE = use_class(weights=terms(
    can_acquire=None, can_redistribute=None, can_use=None,
    stated_by=STATED_BY_NOT_ESTABLISHED, verdict=UNKNOWN,
    note="no rights-holder statement was found"))

# The catalog only ships models whose weights are cleared. The gate still has
# to refuse an uncleared entry if one is ever added, so the test supplies one.
UNCLEARED = ModelEntry(id="eval-only", name="Eval only", task="inpainting",
                       license_id="NOASSERTION", permitted_use=UNCLEARED_USE,
                       source="local", files=(ModelFile("weights.bin"),))

# A flat install that a test can adopt while a reader waits on the legacy lease.
LEGACY = ModelEntry(id="legacy-race", name="Legacy race", task="inpainting",
                    license_id="MIT", permitted_use=CLEARED_USE, source="local",
                    files=(ModelFile("weights.bin"),))

# A model small enough for a test to write whole, so its load path can be
# checked against a real digest instead of only a recorded size.
WEIGHTS = b"weights"
VERIFIED = ModelEntry(
    id="tiny-model", name="Tiny", task="upscaling", license_id="Apache-2.0",
    permitted_use=CLEARED_USE, source="local",
    files=(ModelFile("weights.bin", hashlib.sha256(WEIGHTS).hexdigest(),
                     len(WEIGHTS)),))
UNDIGESTED = ModelEntry(
    id="size-only", name="Size only", task="upscaling", license_id="Apache-2.0",
    permitted_use=CLEARED_USE, source="local", files=(ModelFile("weights.bin", None,
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

    def test_flux_is_admitted_and_listed(self):
        catalog = Catalog(self.root, allow_uncleared=False)
        listed = {entry["id"]: entry for entry in catalog.list()}
        flux = listed["flux2-klein-4b-q4"]["permitted_use"]
        self.assertTrue(flux["admitted"])
        self.assertEqual(flux["weights"]["verdict"], APPROVED)
        self.assertEqual(listed["flux2-klein-4b-q4"]["license"], "Apache-2.0")
        self.assertEqual(len(listed), len(CATALOG))

    def test_every_shipped_record_carries_the_whole_position(self):
        # Finding (3): `Catalog.public()` must carry the record field for field,
        # not a summary of it, so the host and this table cannot disagree.
        catalog = Catalog(self.root, allow_uncleared=False)
        for model in catalog.list():
            record = model["permitted_use"]
            self.assertEqual(set(record),
                             {"code", "weights", "trainingData", "admitted"},
                             model["id"])
            for name in ("code", "weights", "trainingData"):
                self.assertEqual(
                    set(record[name]),
                    {"use", "canAcquire", "canRedistribute", "canUse",
                     "statedBy", "evidenceUrl", "readOn", "verdict",
                     "conditions", "notice", "note"},
                    f"{model['id']} {name}")
                self.assertEqual(record[name]["use"], REQUIRED_USE)
                self.assertTrue(record[name]["evidenceUrl"])
                self.assertTrue(record[name]["readOn"])

    def test_sam_tiny_weights_are_recorded_as_measured(self):
        # Measured 2026-11-18 three ways that agree: the pinned URL streams this
        # many bytes to this digest, HuggingFace's LFS object id for the same
        # path is the same value, and so is the copy this app installed from
        # that URL on 2026-11-08. Until they were recorded, the model could not
        # be verified, could not be adopted into a version, and `require` had no
        # length to check a submission against.
        spec = next(entry for entry in CATALOG
                    if entry.id == "sam2.1-hiera-tiny").files[0]
        self.assertEqual(spec.bytes, 156_008_466)
        self.assertEqual(
            spec.sha256,
            "7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69")

    def test_every_shipped_record_validates(self):
        for entry in CATALOG:
            entry.validate()
            self.assertTrue(entry.license_id, entry.id)
            for name, record in (("code", entry.permitted_use.code),
                                 ("weights", entry.permitted_use.weights),
                                 ("training data", entry.permitted_use.training_data)):
                self.assertIn(record.verdict,
                              (APPROVED, APPROVED_WITH_CONDITIONS, UNKNOWN, EXCLUDED),
                              f"{entry.id} {name}")
                self.assertTrue(record.evidence_url, f"{entry.id} {name}")
                self.assertTrue(record.read_on, f"{entry.id} {name}")

    def test_a_tag_only_weights_statement_is_not_an_admission(self):
        # The mandate's central rule and the review finding (4): inferred
        # evidence can never be a grant, so swin2sr's repository tag is recorded
        # as an inference and the gate refuses it.
        entry = next(item for item in CATALOG if item.id == "swin2sr-x4")
        weights = entry.permitted_use.weights
        self.assertEqual(weights.stated_by, STATED_BY_INFERRED)
        self.assertEqual(weights.verdict, UNKNOWN)
        self.assertIsNone(weights.permitted)
        self.assertFalse(entry.permitted_use.admitted)
        catalog = Catalog(self.root, allow_uncleared=False)
        with self.assertRaises(WorkerError) as caught:
            catalog.require("swin2sr-x4")
        self.assertEqual(caught.exception.code, LICENSE_BLOCKED)
        self.assertEqual(caught.exception.data["verdict"], UNKNOWN)
        self.assertEqual(caught.exception.data["artefact"], "weights")

    def test_an_inferred_statement_can_never_grant_an_axis(self):
        inferred = terms(stated_by=STATED_BY_INFERRED)
        with self.assertRaises(ValueError) as caught:
            inferred.validate()
        self.assertIn("inferred evidence", str(caught.exception))
        # A tag may still be recorded as a blank inference; it just admits nothing.
        blank = terms(stated_by=STATED_BY_INFERRED, can_acquire=None,
                      can_redistribute=None, can_use=None, verdict=UNKNOWN,
                      note="repository tag only")
        blank.validate()
        self.assertIsNone(blank.permitted)
        self.assertFalse(blank.admitted)

    def test_approved_with_conditions_must_list_a_met_condition(self):
        for conditions in ((), (UseCondition("attribute the authors", False),)):
            with self.assertRaises(ValueError):
                terms(verdict=APPROVED_WITH_CONDITIONS,
                      conditions=conditions).validate()
        admitted = terms(verdict=APPROVED_WITH_CONDITIONS,
                         conditions=(UseCondition("attribute the authors", True),))
        admitted.validate()
        self.assertTrue(admitted.admitted)

    def test_a_record_without_its_evidence_is_invalid(self):
        for fields in ({"evidence_url": ""}, {"read_on": ""},
                       {"read_on": "2026-11-31"}, {"read_on": "yesterday"},
                       {"use": "commercial-resale"}):
            with self.assertRaises(ValueError, msg=fields):
                terms(**fields).validate()

    def test_an_excluded_model_is_refused_even_under_the_eval_switch(self):
        # Finding (4): "excluded" plus a permissive boolean must never load.
        excluded = ModelEntry(
            id="excluded-model", name="Excluded", task="upscaling",
            license_id="CC-BY-NC-ND-4.0", permitted_use=use_class(
                weights=terms(verdict=EXCLUDED, can_acquire=False,
                              can_redistribute=False, can_use=False,
                              note="no redistribution or derivative use")),
            source="local", files=(ModelFile("weights.bin"),))
        for allow in (False, True):
            catalog = Catalog(self.root, allow_uncleared=allow)
            with patch("retouch_ai_worker.catalog.CATALOG",
                       CATALOG + (excluded,)):
                with self.assertRaises(WorkerError) as caught:
                    catalog.require("excluded-model")
            self.assertEqual(caught.exception.code, LICENSE_BLOCKED)
            self.assertEqual(caught.exception.data["reason"], "excluded")

    def test_a_refused_entry_still_reports_its_licence_class(self):
        # Scope A: a refused model produces the licence refusal, never an
        # unrelated capability failure, and the message names the artefact.
        catalog = Catalog(self.root, allow_uncleared=False)
        with patch("retouch_ai_worker.catalog.CATALOG", CATALOG + (UNCLEARED,)):
            with self.assertRaises(WorkerError) as caught:
                catalog.require("eval-only")
        self.assertEqual(caught.exception.code, LICENSE_BLOCKED)
        self.assertEqual(caught.exception.data["model"], "eval-only")
        self.assertEqual(caught.exception.data["verdict"], UNKNOWN)

    def test_the_eval_switch_does_not_skip_a_file_check(self):
        catalog = Catalog(self.root, allow_uncleared=True)
        with patch("retouch_ai_worker.catalog.CATALOG", CATALOG + (UNCLEARED,)):
            with self.assertRaises(WorkerError) as caught:
                catalog.require("eval-only")
        self.assertEqual(caught.exception.code, MODEL_MISSING)

    def test_missing_installed_model(self):
        catalog = Catalog(self.root, allow_uncleared=False)
        with self.assertRaises(WorkerError) as caught:
            catalog.require("flux2-klein-4b-q4")
        self.assertEqual(caught.exception.code, MODEL_MISSING)

    def test_installed_model_resolves(self):
        target = self.root / "sam2.1-hiera-tiny" / "sam2.1_hiera_tiny.pt"
        target.parent.mkdir(parents=True)
        # SAM 2.1 tiny's file has had a recorded length since 2026-11-18, so a
        # stub of that length is now what an install must look like to resolve.
        with target.open("wb") as handle:
            handle.truncate(156_008_466)
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
            if entry.permitted_use.weights.verdict == APPROVED:
                self.assertIn(entry.license_id, {"Apache-2.0", "MIT", "BSD-3-Clause"},
                              f"{entry.id} claims its weights are approved")


if __name__ == "__main__":
    unittest.main()
