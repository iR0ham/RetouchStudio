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
                                       ModelFile, normalize_digest, pin_problem)
from retouch_ai_worker.protocol import (BUSY, CATALOG_INVALID, CHECKSUM_MISMATCH,
                                        LICENSE_BLOCKED, MODEL_MISSING,
                                        UNKNOWN_MODEL, WorkerError)

WEIGHTS = b"weights"
SHA_OF_WEIGHTS = hashlib.sha256(WEIGHTS).hexdigest()

# The catalog only ships models whose weights are cleared. The gate still has
# to refuse an uncleared entry if one is ever added, so the test supplies one.
# Its pin is complete, because the licence answer must not depend on a catalog
# defect: an entry with no digest would be refused as unverifiable first.
UNCLEARED = ModelEntry(
    id="eval-only", name="Eval only", task="inpainting",
    license_id="NOASSERTION", commercial_ok=False, source="local",
    files=(ModelFile("weights.bin", hashlib.sha256(WEIGHTS).hexdigest(),
                     len(WEIGHTS)),))

# A flat install that a test can adopt while a reader waits on the legacy lease.
LEGACY = ModelEntry(
    id="legacy-race", name="Legacy race", task="inpainting",
    license_id="MIT", commercial_ok=True, source="local",
    files=(ModelFile("weights.bin", hashlib.sha256(b"w").hexdigest(), 1),))

# A model small enough for a test to write whole, so its load path can be
# checked against a real digest instead of only a recorded size.
VERIFIED = ModelEntry(
    id="tiny-model", name="Tiny", task="upscaling", license_id="Apache-2.0",
    commercial_ok=True, source="local",
    files=(ModelFile("weights.bin", hashlib.sha256(WEIGHTS).hexdigest(),
                     len(WEIGHTS)),))
UNDIGESTED = ModelEntry(
    id="size-only", name="Size only", task="upscaling", license_id="Apache-2.0",
    commercial_ok=True, source="local", files=(ModelFile("weights.bin", None,
                                                         len(WEIGHTS)),))
NOSIZE = ModelEntry(
    id="no-size", name="No size", task="upscaling", license_id="Apache-2.0",
    commercial_ok=True, source="local",
    files=(ModelFile("weights.bin", hashlib.sha256(WEIGHTS).hexdigest(), None),))
BAD_DIGEST = ModelEntry(
    id="bad-digest", name="Bad digest", task="upscaling", license_id="Apache-2.0",
    commercial_ok=True, source="local",
    files=(ModelFile("weights.bin", "g" * 64, len(WEIGHTS)),))
SHORT_DIGEST = ModelEntry(
    id="short-digest", name="Short digest", task="upscaling", license_id="Apache-2.0",
    commercial_ok=True, source="local",
    files=(ModelFile("weights.bin", "abc", len(WEIGHTS)),))
EMPTY_DIGEST = ModelEntry(
    id="empty-digest", name="Empty digest", task="upscaling", license_id="Apache-2.0",
    commercial_ok=True, source="local",
    files=(ModelFile("weights.bin", "", len(WEIGHTS)),))
UPPER_DIGEST = ModelEntry(
    id="upper-digest", name="Upper digest", task="upscaling",
    license_id="Apache-2.0", commercial_ok=True, source="local",
    files=(ModelFile("weights.bin",
                     hashlib.sha256(WEIGHTS).hexdigest().upper(), len(WEIGHTS)),))
NO_FILES = ModelEntry(
    id="no-files", name="No files", task="upscaling", license_id="Apache-2.0",
    commercial_ok=True, source="local", files=())


def _with(*entries):
    """The shipped catalog plus synthetic fixtures, for one `with` block."""
    return patch("retouch_ai_worker.catalog.CATALOG", CATALOG + entries)


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

    def test_unlicensed_model_is_refused(self):
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(UNCLEARED):
            for accessor in (catalog.require, catalog.require_verified):
                with self.subTest(accessor=accessor.__name__):
                    with self.assertRaises(WorkerError) as caught:
                        accessor("eval-only")
                    self.assertEqual(caught.exception.code, LICENSE_BLOCKED)

    def test_the_research_switch_never_bypasses_an_integrity_check(self):
        # `RETOUCH_AI_EVAL_MODELS` is a licence switch and nothing else. The
        # measured baseline let an entry pass under it on size alone; now the
        # only thing it changes is the `commercial_ok` gate.
        folder = self.root / UNCLEARED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(b"TAMPRED")   # right length, wrong bytes
        catalog = Catalog(self.root, allow_uncleared=True)
        self.assertTrue(catalog.allow_uncleared)
        with _with(UNCLEARED):
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(UNCLEARED.id)
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(caught.exception.data["reason"], "digest")
        self.assertEqual(catalog._leases, {})

        pinless = ModelEntry(
            id=UNCLEARED.id, name=UNCLEARED.name, task=UNCLEARED.task,
            license_id=UNCLEARED.license_id, commercial_ok=False,
            source=UNCLEARED.source, files=(ModelFile("weights.bin", None, 7),))
        catalog = Catalog(self.root, allow_uncleared=True)
        with _with(pinless):
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(pinless.id)
        # Admission outranks the switch: an uncleared *and* unverifiable entry is
        # still refused, and refused for the reason a repair can act on.
        self.assertEqual(caught.exception.code, CATALOG_INVALID)

    def test_eval_switch_allows_but_then_requires_files(self):
        catalog = Catalog(self.root, allow_uncleared=True)
        with _with(UNCLEARED):
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
        with _with(VERIFIED):
            self.assertEqual(catalog.require_verified(VERIFIED.id), folder)
        self.assertEqual(len(catalog._leases), 1)

    def test_a_file_that_does_not_match_its_digest_is_refused(self):
        # Same length, different bytes: the size gate in `require` cannot see
        # this, which is what the load-time digest is for.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            self.assertEqual(catalog.require_verified(VERIFIED.id), folder)
            (folder / "weights.bin").write_bytes(b"tampered")
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(caught.exception.data["file"], "weights.bin")
        # A model that failed its checksum stays deletable.
        self.assertEqual(catalog._leases, {})

    def test_an_entry_without_a_recorded_digest_is_refused(self):
        # This test used to assert the opposite: that a pinless entry "loads on
        # size". That assertion encoded the defect. `require_verified` returned
        # the root after hashing nothing, and `verify()` reported ok with
        # checked: 0, so an entry added without a digest silently became
        # trusted. It is now refused before a byte is read.
        folder = self.root / UNDIGESTED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(UNDIGESTED):
            for accessor in (catalog.require, catalog.require_verified):
                with self.subTest(accessor=accessor.__name__):
                    with self.assertRaises(WorkerError) as caught:
                        accessor(UNDIGESTED.id)
                    self.assertEqual(caught.exception.code, CATALOG_INVALID)
                    self.assertEqual(caught.exception.data["reason"],
                                     "missing-digest")
                    self.assertEqual(caught.exception.data["model"], UNDIGESTED.id)
                    self.assertEqual(caught.exception.data["file"], "weights.bin")
            # Unverifiable is not missing: no download can supply the digest.
            self.assertNotEqual(CATALOG_INVALID, MODEL_MISSING)
            # The lease a refused load may have taken is dropped, so the install
            # stays deletable.
            self.assertEqual(catalog._leases, {})
            # It still appears in the listing, so the UI can say why it is unusable.
            self.assertIn(UNDIGESTED.id, [entry["id"] for entry in catalog.list()])

    def test_an_entry_without_a_recorded_size_is_refused(self):
        folder = self.root / NOSIZE.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(NOSIZE):
            for accessor in (catalog.require, catalog.require_verified):
                with self.subTest(accessor=accessor.__name__):
                    with self.assertRaises(WorkerError) as caught:
                        accessor(NOSIZE.id)
                    self.assertEqual(caught.exception.code, CATALOG_INVALID)
                    self.assertEqual(caught.exception.data["reason"], "missing-size")
                    self.assertEqual(caught.exception.data["file"], "weights.bin")
            self.assertEqual(catalog._leases, {})

    def test_a_malformed_digest_is_refused_as_a_catalog_defect(self):
        # An absent pin and an empty one are the same defect (`missing-digest`);
        # this table covers the pins that are present but malformed: truncated,
        # non-hex, and a digest of the wrong width. They can never equal
        # hexdigest(), so the old code rejected them by accident while blaming the
        # weights. They are now named as what they are, at admission, before any
        # file is opened.
        for entry, label in ((SHORT_DIGEST, "short"), (BAD_DIGEST, "non-hex"),
                             (ModelEntry(
                                 id="odd-length", name="Odd length",
                                 task="upscaling", license_id="Apache-2.0",
                                 commercial_ok=True, source="local",
                                 files=(ModelFile("weights.bin", SHA_OF_WEIGHTS + "a",
                                                  len(WEIGHTS)),),),
                              "65 chars")):
            with self.subTest(pin=label):
                folder = self.root / entry.id
                folder.mkdir()
                (folder / "weights.bin").write_bytes(WEIGHTS)
                catalog = Catalog(self.root, allow_uncleared=False)
                with _with(entry):
                    for accessor in (catalog.require, catalog.require_verified):
                        with self.subTest(pin=label, accessor=accessor.__name__):
                            with self.assertRaises(WorkerError) as caught:
                                accessor(entry.id)
                            self.assertEqual(caught.exception.code, CATALOG_INVALID)
                            self.assertEqual(caught.exception.data["reason"],
                                             "invalid-digest")
                            self.assertIn("64 hexadecimal",
                                          caught.exception.message)
                    self.assertEqual(catalog._leases, {})

    def test_an_empty_digest_is_refused_as_a_missing_one(self):
        # "" is not a malformed 64-character digest, it is no digest at all. The
        # distinction matters to the repair the UI can offer, so it gets its own
        # reason rather than being folded into `invalid-digest`.
        folder = self.root / EMPTY_DIGEST.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(EMPTY_DIGEST):
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(EMPTY_DIGEST.id)
        self.assertEqual(caught.exception.code, CATALOG_INVALID)
        self.assertEqual(caught.exception.data["reason"], "missing-digest")

    def test_normalize_digest_accepts_only_64_hex_characters(self):
        for value in (None, "", "abc", "g" * 64, SHA_OF_WEIGHTS + "a",
                      SHA_OF_WEIGHTS.encode().hex(), 0):
            with self.subTest(value=repr(value)):
                self.assertIsNone(normalize_digest(value))
        self.assertEqual(normalize_digest(SHA_OF_WEIGHTS), SHA_OF_WEIGHTS)
        self.assertEqual(normalize_digest(SHA_OF_WEIGHTS.upper()), SHA_OF_WEIGHTS)

    def test_pin_problem_names_the_first_defect_in_catalog_order(self):
        self.assertIsNone(pin_problem(VERIFIED))
        two_files = ModelEntry(
            id="mixed", name="Mixed", task="upscaling", license_id="MIT",
            commercial_ok=True, source="local",
            files=(ModelFile("good.bin", SHA_OF_WEIGHTS, len(WEIGHTS)),
                   ModelFile("bad.bin", None, len(WEIGHTS))))
        problem = pin_problem(two_files)
        self.assertEqual(problem[0], "missing-digest")
        self.assertEqual(problem[1], "bad.bin")
        self.assertIn("bad.bin", problem[2])
        self.assertEqual(pin_problem(NO_FILES)[:2], ("incomplete-entry", ""))

    def test_an_unreadable_file_is_refused_rather_than_reported_missing(self):
        # A name that stats but will not open. Calling this "not installed"
        # offers a download over bytes that are sitting right there; the honest
        # answer is that the worker could not verify what it has.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        target = folder / "weights.bin"
        target.write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED), patch("retouch_ai_worker.catalog._sha256",
                                    side_effect=OSError("I/O error")):
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(caught.exception.data["reason"], "unreadable")
        self.assertEqual(caught.exception.data["file"], "weights.bin")
        self.assertEqual(catalog._leases, {})

    def test_a_digest_mismatch_names_the_model_file_and_both_digests(self):
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(b"TAMPRED")   # same length, wrong bytes
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
        data = caught.exception.data
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(data["model"], VERIFIED.id)
        self.assertEqual(data["file"], "weights.bin")
        self.assertEqual(data["reason"], "digest")
        self.assertEqual(data["expected_sha256"],
                         hashlib.sha256(WEIGHTS).hexdigest())
        self.assertEqual(data["actual_sha256"],
                         hashlib.sha256(b"TAMPRED").hexdigest())
        self.assertEqual(catalog._leases, {})

    def test_an_uppercase_pin_verifies_the_same_file(self):
        # 64 upper-case hex characters are a valid SHA-256 written in another
        # case. Comparing it to hexdigest() verbatim would reject a correct file
        # forever, so the comparison is normalised instead of the pin being
        # thrown away.
        folder = self.root / UPPER_DIGEST.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(UPPER_DIGEST):
            self.assertEqual(catalog.require_verified(UPPER_DIGEST.id), folder)
            self.assertEqual(catalog.verify(UPPER_DIGEST.id)["ok"], True)
            self.assertTrue(catalog.health()["ok"])

    def test_a_correctly_pinned_model_still_loads(self):
        # The positive control for every refusal above: tightening admission must
        # not break the ordinary path, in either install layout.
        version = self.root / VERIFIED.id / "1.0.0"
        version.mkdir(parents=True)
        (version / "weights.bin").write_bytes(WEIGHTS)
        (self.root / VERIFIED.id / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": VERIFIED.id, "version": "1.0.0",
        }), encoding="utf-8")
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            self.assertEqual(catalog.require_verified(VERIFIED.id), version)
            self.assertEqual(catalog.require(VERIFIED.id), version)
            self.assertEqual(catalog.verify(VERIFIED.id),
                             {"model": VERIFIED.id, "checked": 1, "failed": [],
                              "ok": True})
            health = catalog.health()
            self.assertTrue(health["ok"], health)
            # One lease, not two: `require` and `require_verified` describe the
            # same artifact, and re-taking it must not leak a descriptor per call.
            self.assertEqual(len(catalog._leases), 1)
            catalog.release(VERIFIED.id, version)
            self.assertEqual(catalog._leases, {})

    def test_a_rewritten_file_is_not_accepted_on_a_cached_proof(self):
        # The memoised digest is a cache, not a licence. Replacing the bytes
        # changes the artifact identity, so the next load must hash again and
        # refuse — otherwise "verified once per process" would mean "trusted
        # whatever is there later".
        folder = self.root / VERIFIED.id
        folder.mkdir()
        target = folder / "weights.bin"
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            target.write_bytes(WEIGHTS)
            self.assertEqual(catalog.require_verified(VERIFIED.id), folder)
            self.assertEqual(len(catalog._proofs), 1)
            # Truncate as well as rewrite: the digest is the last gate for a file
            # whose length still matched, and that is the case this cache must
            # not paper over.
            target.write_bytes(b"short")
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
            self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
            self.assertEqual(caught.exception.data["reason"], "size")
            # Same length, different content: the size gate passes and only the
            # digest can notice, so the proof must be recomputed here too. The
            # mtime is bumped deliberately — a substitution that preserves the
            # recorded modification time as well as the length is below what any
            # in-process cache can detect, and it is `models verify`'s job.
            target.write_bytes(b"TAMPRED")
            os.utime(target, (time.time() + 2, time.time() + 2))
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
            self.assertEqual(caught.exception.data["reason"], "digest")
            self.assertEqual(len(catalog._proofs), 1,
                             "the stale proof was replaced, not reused")

    def test_a_changed_catalog_invalidates_a_cached_proof(self):
        # Two entries pinning different digests for one path: a proof recorded
        # under the first must not satisfy the second.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        other = ModelEntry(
            id=VERIFIED.id, name="Other pin", task="upscaling",
            license_id="Apache-2.0", commercial_ok=True, source="local",
            files=(ModelFile("weights.bin", hashlib.sha256(b"different!").hexdigest(),
                             len(WEIGHTS)),))
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            self.assertEqual(catalog.require_verified(VERIFIED.id), folder)
        with _with(other):
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
            self.assertEqual(caught.exception.data["reason"], "digest")

    def test_health_reports_an_unverifiable_entry_instead_of_calling_it_ok(self):
        # Measured fail-open: `health()` used to answer {installed: true, ok:
        # true} for a pinless or size-less entry, and for one listing no files at
        # all, because both checks were skipped when the pin was null.
        for entry, reason in ((UNDIGESTED, "missing-digest"),
                              (NOSIZE, "missing-size"),
                              (BAD_DIGEST, "invalid-digest"),
                              (NO_FILES, "incomplete-entry")):
            with self.subTest(entry=entry.id):
                folder = self.root / entry.id
                folder.mkdir()
                if entry.files:
                    (folder / "weights.bin").write_bytes(WEIGHTS)
                catalog = Catalog(self.root, allow_uncleared=False)
                with _with(entry):
                    report = catalog.health()
                self.assertFalse(report["ok"], report)
                state = {item["model"]: item for item in report["models"]}[entry.id]
                self.assertEqual(state["problems"], [{"file": "weights.bin"
                                                      if entry.files else "",
                                                      "reason": reason}])

    def test_health_still_reports_a_size_problem_and_ignores_nothing(self):
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(b"longer than the pin")
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            report = catalog.health()
        self.assertFalse(report["ok"])
        state = {item["model"]: item for item in report["models"]}[VERIFIED.id]
        self.assertEqual(state["problems"],
                         [{"file": "weights.bin", "reason": "size"}])

    def test_verify_reports_unverifiable_instead_of_ok_with_nothing_checked(self):
        # Measured fail-open: a pinless entry returned {checked: 0, failed: [],
        # ok: true}, i.e. a clean bill of health for bytes it never read.
        for entry, reason in ((UNDIGESTED, "missing-digest"),
                              (NOSIZE, "missing-size"),
                              (BAD_DIGEST, "invalid-digest")):
            with self.subTest(entry=entry.id):
                folder = self.root / entry.id
                folder.mkdir()
                (folder / "weights.bin").write_bytes(WEIGHTS)
                catalog = Catalog(self.root, allow_uncleared=False)
                with _with(entry):
                    report = catalog.verify(entry.id)
                self.assertFalse(report["ok"])
                self.assertEqual(report["checked"], 0)
                self.assertTrue(report["unverifiable"])
                self.assertEqual(report["failed"][0]["reason"], reason)

    def test_verify_reports_a_size_failure_before_hashing(self):
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(b"shrt")
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            report = catalog.verify(VERIFIED.id)
        self.assertFalse(report["ok"])
        self.assertEqual(report["failed"][0]["reason"], "size")
        self.assertEqual(report["failed"][0]["expected_bytes"], len(WEIGHTS))
        self.assertEqual(report["failed"][0]["actual_bytes"], 4)

    def test_an_unknown_model_is_refused_whatever_the_switch_or_layout(self):
        # The catalog is an allow-list: neither the research switch nor complete
        # bytes on disk can make an unlisted id resolvable.
        catalog = Catalog(self.root, allow_uncleared=True)
        for method in ("get", "require", "require_verified"):
            with self.subTest(method=method):
                with self.assertRaises(WorkerError) as caught:
                    getattr(catalog, method)("nope")
                self.assertEqual(caught.exception.code, UNKNOWN_MODEL)
                self.assertEqual(caught.exception.data["model"], "nope")
        for traversal in ("../../etc", "../migan", ""):
            with self.subTest(model_id=traversal):
                with self.assertRaises(WorkerError) as caught:
                    catalog.get(traversal)
                self.assertEqual(caught.exception.code, UNKNOWN_MODEL)

    def test_a_directory_that_is_not_a_complete_install_is_still_missing(self):
        # A version folder holding only the app's manifest.json has none of the
        # catalog's files. That stays MODEL_MISSING, so the UI offers a download;
        # the worker deliberately does not treat the store manifest as a trust
        # input (the app verifies it before publishing the pointer).
        folder = self.root / VERIFIED.id / "1.0.0"
        folder.mkdir(parents=True)
        (folder / "manifest.json").write_text("{not json", encoding="utf-8")
        (self.root / VERIFIED.id / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": VERIFIED.id, "version": "1.0.0",
        }), encoding="utf-8")
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            for accessor in (catalog.require, catalog.require_verified):
                with self.subTest(accessor=accessor.__name__):
                    with self.assertRaises(WorkerError) as caught:
                        accessor(VERIFIED.id)
                    self.assertEqual(caught.exception.code, MODEL_MISSING)
                    self.assertEqual(caught.exception.data["missing"], "weights.bin")
                    self.assertEqual(caught.exception.data["reason"], "not-installed")
        self.assertEqual(catalog._leases, {})

    def test_the_shipped_catalog_admits_every_entry(self):
        # The positive admission control for the shipped pins: tightening the
        # rules must not strand a model the product actually ships.
        for entry in CATALOG:
            with self.subTest(model=entry.id):
                self.assertIsNone(pin_problem(entry))
                for spec in entry.files:
                    self.assertIsInstance(spec.bytes, int)
                    self.assertGreater(spec.bytes, 0)
                    self.assertEqual(normalize_digest(spec.sha256), spec.sha256)

    def test_unknown_model(self):
        with self.assertRaises(WorkerError) as caught:
            Catalog(self.root).get("nope")
        self.assertEqual(caught.exception.code, UNKNOWN_MODEL)

    def test_verify_detects_tampering(self):
        target = self.root / "flux2-klein-4b-q4" / "vae" / "0.safetensors"
        target.parent.mkdir(parents=True)
        # The length has to be right or the size gate answers first, and this
        # test is about the digest.
        with target.open("wb") as handle:
            handle.truncate(165_107_888)
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
            with _with(LEGACY), \
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
            with _with(LEGACY), \
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
