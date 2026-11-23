import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from dataclasses import replace
from pathlib import Path

from unittest.mock import patch

from retouch_ai_worker import catalog as catalog_module
from retouch_ai_worker.catalog import (APPROVED, APPROVED_WITH_CONDITIONS, CATALOG,
                                       EXCLUDED, LEGACY_LEASE, LICENCE_READ_ON,
                                       REQUIRED_USE, STATED_BY_INFERRED,
                                       STATED_BY_NOT_ESTABLISHED,
                                       STATED_BY_RIGHTS_HOLDER, UNKNOWN,
                                       ArtefactTerms, Catalog, ModelEntry,
                                       ModelFile, PermittedUse, UseCondition,
                                       normalize_digest, pin_problem)
from retouch_ai_worker.plan import manifest
from retouch_ai_worker.protocol import (BUSY, CATALOG_INVALID, CHECKSUM_MISMATCH,
                                        LICENSE_BLOCKED, MODEL_MISSING,
                                        UNKNOWN_MODEL, WorkerError)

WEIGHTS = b"weights"
SHA_OF_WEIGHTS = hashlib.sha256(WEIGHTS).hexdigest()

# The worker package's parent, so a subprocess can import the real module.
WORKER_DIR = Path(catalog_module.__file__).resolve().parent.parent
PROBE_TEMPLATE = """
import json, sys
sys.path.insert(0, %r)
from retouch_ai_worker.catalog import Catalog
catalog = Catalog(%r, allow_uncleared=False)
print(json.dumps({"proofs": len(catalog._proofs)}))
"""

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
# Its pin is complete, because the licence answer must not depend on a catalog
# defect: an entry with no digest would be refused as unverifiable first, and the
# test would prove nothing about the licence gate.
UNCLEARED = ModelEntry(
    id="eval-only", name="Eval only", task="inpainting",
    license_id="NOASSERTION", permitted_use=UNCLEARED_USE, source="local",
    files=(ModelFile("weights.bin", SHA_OF_WEIGHTS, len(WEIGHTS)),))

# A flat install that a test can adopt while a reader waits on the legacy lease.
LEGACY = ModelEntry(
    id="legacy-race", name="Legacy race", task="inpainting",
    license_id="MIT", permitted_use=CLEARED_USE, source="local",
    files=(ModelFile("weights.bin", hashlib.sha256(b"w").hexdigest(), 1),))
# A model small enough for a test to write whole, so its load path can be
# checked against a real digest instead of only a recorded size.
VERIFIED = ModelEntry(
    id="tiny-model", name="Tiny", task="upscaling", license_id="Apache-2.0",
    permitted_use=CLEARED_USE, source="local",
    files=(ModelFile("weights.bin", hashlib.sha256(WEIGHTS).hexdigest(),
                     len(WEIGHTS)),))
UNDIGESTED = ModelEntry(
    id="size-only", name="Size only", task="upscaling", license_id="Apache-2.0",
    permitted_use=CLEARED_USE, source="local", files=(ModelFile("weights.bin", None,
                                                               len(WEIGHTS)),))
NOSIZE = ModelEntry(
    id="no-size", name="No size", task="upscaling", license_id="Apache-2.0",
    permitted_use=CLEARED_USE, source="local",
    files=(ModelFile("weights.bin", SHA_OF_WEIGHTS, None),))
BAD_DIGEST = ModelEntry(
    id="bad-digest", name="Bad digest", task="upscaling", license_id="Apache-2.0",
    permitted_use=CLEARED_USE, source="local",
    files=(ModelFile("weights.bin", "g" * 64, len(WEIGHTS)),))
SHORT_DIGEST = ModelEntry(
    id="short-digest", name="Short digest", task="upscaling", license_id="Apache-2.0",
    permitted_use=CLEARED_USE, source="local",
    files=(ModelFile("weights.bin", "abc", len(WEIGHTS)),))
EMPTY_DIGEST = ModelEntry(
    id="empty-digest", name="Empty digest", task="upscaling", license_id="Apache-2.0",
    permitted_use=CLEARED_USE, source="local",
    files=(ModelFile("weights.bin", "", len(WEIGHTS)),))
UPPER_DIGEST = ModelEntry(
    id="upper-digest", name="Upper digest", task="upscaling", license_id="Apache-2.0",
    permitted_use=CLEARED_USE, source="local",
    files=(ModelFile("weights.bin", SHA_OF_WEIGHTS.upper(), len(WEIGHTS)),))
NO_FILES = ModelEntry(
    id="no-files", name="No files", task="upscaling", license_id="Apache-2.0",
    permitted_use=CLEARED_USE, source="local", files=())


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

    def test_flux_weights_are_unknown_and_the_gate_refuses_them(self):
        # S-FLUX, 2026-11-23. The shipped record used to quote "Open weights
        # available for commercial use under the Apache 2.0 license" — a sentence
        # Black Forest Labs speaks about `black-forest-labs/FLUX.2-klein-4B` — as
        # the permission of `mflux-community/flux2-klein-4b-mflux-q4`, the
        # community conversion this entry actually downloads and whose own card
        # disclaims authorship. Recording an upstream statement as a derivative's
        # grant is the inference this schema exists to refuse, so the artefact is
        # UNKNOWN and the existing gate refuses it. Nothing new was added to make
        # that happen: the refusal comes out of `weights.admitted` requiring an
        # approving verdict, `PermittedUse.admitted` being
        # `weights.admitted and not excluded`, and `_require_licensed` /
        # `plan.manifest` raising `LICENSE_BLOCKED`.
        catalog = Catalog(self.root, allow_uncleared=False)
        listed = {entry["id"]: entry for entry in catalog.list()}
        flux = listed["flux2-klein-4b-q4"]["permitted_use"]
        self.assertFalse(flux["admitted"])
        self.assertEqual(flux["weights"]["verdict"], UNKNOWN)
        self.assertEqual([flux["weights"][axis] for axis in
                          ("canAcquire", "canRedistribute", "canUse")],
                         [None, None, None],
                         "an unknown verdict may not state a granted axis")
        self.assertEqual(listed["flux2-klein-4b-q4"]["license"], "Apache-2.0")
        self.assertEqual(len(listed), len(CATALOG))

        # Both accessors refuse before any disk state, and the payload names the
        # artefact and its verdict so the host can say why in its own words.
        for accessor in (catalog.require, catalog.require_verified):
            with self.subTest(accessor=accessor.__name__):
                with self.assertRaises(WorkerError) as caught:
                    accessor("flux2-klein-4b-q4")
                self.assertEqual(caught.exception.code, LICENSE_BLOCKED)
                self.assertEqual(caught.exception.data["verdict"], UNKNOWN)
                self.assertEqual(caught.exception.data["artefact"], "weights")
                self.assertEqual(caught.exception.data["model"], "flux2-klein-4b-q4")
                self.assertIn("no established permission", str(caught.exception))
        # The download manifest is refused too, so no consent sheet is ever
        # priced for 4.6 GB this worker will not load.
        with self.assertRaises(WorkerError) as caught:
            manifest(["flux2-klein-4b-q4"], catalog)
        self.assertEqual(caught.exception.code, LICENSE_BLOCKED)
        self.assertEqual(caught.exception.data["verdict"], UNKNOWN)
        # And the refusal costs nothing: no lease survives it.
        self.assertEqual(catalog._leases, {})

    def test_the_flux_unknown_record_states_what_is_missing(self):
        # A validator rule makes an `unknown` verdict carry a note; this pins the
        # note's *content*, because the whole point of the downgrade is that a
        # future re-record must inherit the anchor instead of re-deriving it.
        weights = next(entry for entry in CATALOG
                       if entry.id == "flux2-klein-4b-q4").permitted_use.weights
        self.assertEqual(weights.stated_by, STATED_BY_NOT_ESTABLISHED)
        self.assertIsNone(weights.permitted)
        self.assertFalse(weights.admitted)
        self.assertFalse(weights.conditions)
        note = weights.note or ""
        # The note is the tooltip a user can actually open, so it is a summary
        # with a pointer; §12 below is where the evidence lives. These phrases are
        # the summary's load-bearing parts: what is missing from the artefact, the
        # revision the grant is anchored to, and the fact that this entry was
        # downgraded rather than never assessed.
        for phrase in ("ships no licence copy",
                       "states no upstream revision",
                       "the converter head has moved",
                       "black-forest-labs/FLUX.2-klein-4B",
                       "e7b7dc27f91deacad38e78976d1f2b499d76a294",
                       "PR #121",
                       "tokenizer"):
            self.assertIn(phrase, note, phrase)
        # The pointer must resolve, or the summary is an orphan citing a section
        # nobody kept. This is the only test that reads the dossier, and it reads
        # it to prove the evidence trail exists, not to restate it.
        self.assertIn("Docs/MODEL_LICENCES.md section 12", note)
        dossier = (Path(__file__).resolve().parents[2]
                   / "Docs" / "MODEL_LICENCES.md").read_text(encoding="utf-8")
        self.assertIn("## 12. Addendum, 2026-11-23", dossier)
        for phrase in ("Community conversion by",
                       "no licence file of any kind",
                       "794cd159538149ad9830848508c31f0ea7088e58",
                       "Flux2KleinEdit",
                       "download_patterns"):
            self.assertIn(phrase, dossier, phrase)
        # Attribution discipline: the converter URL stays the evidence for the
        # artefact, and the upstream grant is never recorded as this artefact's
        # own statement source.
        self.assertEqual(weights.evidence_url,
                         "https://huggingface.co/mflux-community/flux2-klein-4b-mflux-q4")
        self.assertNotEqual(weights.stated_by, STATED_BY_RIGHTS_HOLDER)

    def test_an_upstream_statement_never_grants_a_derivative(self):
        # The *shape* of the S-FLUX mistake, made unrepresentable rather than
        # merely absent from today's data. An artefact whose own card disclaims
        # authorship carried `stated_by=rights-holder` because a sentence spoken
        # about its upstream source was quoted at its URL. Nothing in the schema
        # can tell those two repositories apart — the validator sees one URL and
        # cannot reach the network — so what is pinned here is the pair of rules
        # that together leave the mistake nowhere to live: a `not-established`
        # record may state no permission (`catalog.py:197-200`), and only an
        # approving verdict with every axis granted admits
        # (`catalog.py:160-166`, `catalog.py:274`).
        derivative = ModelEntry(
            id="derivative-conversion", name="Community conversion", task="upscaling",
            license_id="Apache-2.0",
            permitted_use=use_class(weights=terms(
                notice="Apache-2.0. Redistributing these weights requires the licence "
                       "copy, the retained notices and a statement of changes.",
                note="\"Open weights available for commercial use under the Apache 2.0 "
                     "license\" — a sentence the upstream author speaks about its own "
                     "repository. This card says \"Community conversion — not an official "
                     "release from the original model's authors\".")),
            source="hf:someone/conversion-of-upstream",
            files=(ModelFile("weights.bin", SHA_OF_WEIGHTS, len(WEIGHTS)),))

        # 1. The wrong shape still validates and still admits, which is why rule 2
        #    has to be enforced by a second layer: the schema alone cannot see that
        #    the quoted sentence belongs to a different repository. Recording this
        #    explicitly keeps the claim honest, and it is the reason the shipped
        #    table carries the marker sweep in
        #    `test_the_shipped_table_holds_no_upstream_statement_at_a_derivative_url`.
        derivative.permitted_use.validate()
        self.assertTrue(derivative.permitted_use.admitted)

        # 2. Re-recorded honestly — the search at *this* artefact found no
        #    statement — every granted axis becomes invalid, so the mistake cannot
        #    survive the correction. The axes are the only thing that changed.
        for axis in ("can_acquire", "can_redistribute", "can_use"):
            corrected = terms(stated_by=STATED_BY_NOT_ESTABLISHED, verdict=UNKNOWN,
                              note="the converter ships no licence file and disclaims "
                                   "authorship; the quoted grant belongs to the upstream "
                                   "repository")
            corrected = replace(corrected, **{axis: True})
            with self.subTest(granted_axis=axis):
                with self.assertRaises(ValueError) as caught:
                    corrected.validate()
                self.assertIn("records a decision", str(caught.exception))

        # 3. And a record that grants nothing admits nothing: the loader refuses
        #    it for the licence reason, never the missing-file one.
        honest = ModelEntry(
            id=derivative.id, name=derivative.name, task=derivative.task,
            license_id=derivative.license_id,
            permitted_use=replace(derivative.permitted_use, weights=terms(
                can_acquire=None, can_redistribute=None, can_use=None,
                stated_by=STATED_BY_NOT_ESTABLISHED, verdict=UNKNOWN,
                note="no licence file in this repository; the card disclaims authorship")),
            source=derivative.source, files=derivative.files)
        honest.validate()
        self.assertFalse(honest.permitted_use.admitted)
        self.assertIsNone(honest.permitted_use.weights.permitted)
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(honest):
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(honest.id)
        self.assertEqual(caught.exception.code, LICENSE_BLOCKED)
        self.assertEqual(caught.exception.data["verdict"], UNKNOWN)
        # Even the research switch cannot put it back: it opens the admission gate
        # for evaluation, and once it is open the ordinary install answer returns,
        # which is the only difference the switch is allowed to make.
        with _with(honest):
            with self.assertRaises(WorkerError) as caught:
                Catalog(self.root, allow_uncleared=True).require(honest.id)
        self.assertEqual(caught.exception.code, MODEL_MISSING)

    def test_the_shipped_table_holds_no_upstream_statement_at_a_derivative_url(self):
        # The same rule measured against the shipped data, so a future re-record
        # has to earn its way past it: any entry whose note itself reports that the
        # artefact disclaims authorship or carries no licence may not record a
        # granted axis. This is the guard the FLUX row failed in the other
        # direction — its own note quoted the upstream sentence while pointing at
        # the converter.
        markers = ("not an official release", "community conversion",
                   "no license file", "no licence file", "ships no LICENSE")
        for entry in CATALOG:
            for name, record in (("code", entry.permitted_use.code),
                                 ("weights", entry.permitted_use.weights),
                                 ("training data", entry.permitted_use.training_data)):
                text = " ".join(filter(None, (record.note, record.notice))).lower()
                disclaiming = any(marker in text for marker in markers)
                with self.subTest(entry=entry.id, artefact=name):
                    if disclaiming:
                        self.assertNotEqual(
                            record.stated_by, STATED_BY_RIGHTS_HOLDER,
                            f"{entry.id} {name} records a rights-holder grant for an "
                            "artefact whose own record says it is a disclaimer-of-"
                            "authorship derivative")
                        self.assertIsNone(record.permitted)
                        self.assertFalse(record.admitted)

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

    def test_swin_weights_are_approved_with_met_conditions(self):
        # The release manager's 2026-11-22 decision under the owner's standing
        # execution mandate, on evidence read that day and re-read 2026-11-23: the
        # Hugging Face uploader `caidas` is the verified organisation of the
        # paper's own lab ("Computer Vision Lab, CAIDAS, University of
        # Würzburg"), and the upstream project states its own Apache 2.0
        # release. That is a rights-holder statement about the weights, not an
        # inference by us, so the record carries the grant with four conditions
        # and the gate admits it. This entry used to be recorded `unknown` /
        # `inferred`, which reported `upscale.4x` — the one shipped AI
        # capability — as blocked; see Docs/MODEL_LICENCES.md §8.
        entry = next(item for item in CATALOG if item.id == "swin2sr-x4")
        weights = entry.permitted_use.weights
        self.assertEqual(weights.stated_by, STATED_BY_RIGHTS_HOLDER)
        self.assertEqual(weights.verdict, APPROVED_WITH_CONDITIONS)
        self.assertIs(weights.permitted, True)
        self.assertTrue(weights.conditions)
        self.assertTrue(all(condition.met for condition in weights.conditions))
        self.assertTrue(entry.permitted_use.admitted)
        # The training-data axis stays unknown: the addendum records the
        # DIV2K/Flickr2K quote and does not resolve the per-checkpoint mix.
        training = entry.permitted_use.training_data
        self.assertEqual(training.verdict, UNKNOWN)
        self.assertIsNone(training.permitted)
        self.assertIn("DIV2K", training.note)
        self.assertIn("Flickr2K", training.note)
        # A condition-bearing record must state every condition it depends on.
        catalog = Catalog(self.root, allow_uncleared=False)
        listed = {item["id"]: item for item in catalog.list()}
        record = listed["swin2sr-x4"]["permitted_use"]
        self.assertTrue(record["admitted"])
        self.assertEqual([item["met"] for item in record["weights"]["conditions"]],
                         [True] * len(weights.conditions))
        # And the load gate really lets it through: no weights file is installed
        # here, so the refusal must be the ordinary missing-model error and never
        # the licence error.
        with self.assertRaises(WorkerError) as caught:
            catalog.require("swin2sr-x4")
        self.assertNotEqual(caught.exception.code, LICENSE_BLOCKED)

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
        with _with(UNCLEARED):
            for accessor in (catalog.require, catalog.require_verified):
                with self.subTest(accessor=accessor.__name__):
                    with self.assertRaises(WorkerError) as caught:
                        accessor("eval-only")
                    self.assertEqual(caught.exception.code, LICENSE_BLOCKED)

    def test_the_research_switch_never_bypasses_an_integrity_check(self):
        # `RETOUCH_AI_EVAL_MODELS` is a licence switch and nothing else. The
        # measured baseline let an entry pass under it on size alone; now the
        # only thing it changes is the admission gate in `_require_licensed`,
        # which is a licence refusal and nothing else.
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
            license_id=UNCLEARED.license_id, permitted_use=UNCLEARED_USE,
            source=UNCLEARED.source, files=(ModelFile("weights.bin", None, 7),))
        catalog = Catalog(self.root, allow_uncleared=True)
        with _with(pinless):
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(pinless.id)
        # Admission outranks the switch: an uncleared *and* unverifiable entry is
        # still refused, and refused for the reason a repair can act on.
        self.assertEqual(caught.exception.code, CATALOG_INVALID)
        with _with(UNCLEARED):
            catalog = Catalog(self.root)
            with self.assertRaises(WorkerError) as caught:
                catalog.require("eval-only")
        self.assertEqual(caught.exception.code, LICENSE_BLOCKED)
        self.assertEqual(caught.exception.data["model"], "eval-only")
        self.assertEqual(caught.exception.data["verdict"], UNKNOWN)
    def test_the_eval_switch_does_not_skip_a_file_check(self):
        catalog = Catalog(self.root, allow_uncleared=True)
        with _with(UNCLEARED):
            with self.assertRaises(WorkerError) as caught:
                catalog.require("eval-only")
        self.assertEqual(caught.exception.code, MODEL_MISSING)

    def test_missing_installed_model(self):
        # `flux2-klein-4b-q4` used to stand in for "not installed". Since S-FLUX
        # its own record refuses the load on licence before disk is ever consulted
        # — which is the ordering the gate documents — so the missing-model answer
        # comes from an entry that *is* admitted, and the licence answer is pinned
        # by `test_flux_weights_are_unknown_and_the_gate_refuses_them`.
        catalog = Catalog(self.root, allow_uncleared=False)
        with self.assertRaises(WorkerError) as caught:
            catalog.require("swin2sr-x4")
        self.assertEqual(caught.exception.code, MODEL_MISSING)
        self.assertEqual(caught.exception.data["reason"], "not-installed")

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
                                 permitted_use=CLEARED_USE, source="local",
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
            permitted_use=CLEARED_USE, source="local",
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
            license_id="Apache-2.0", permitted_use=CLEARED_USE, source="local",
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

    def test_a_pin_for_an_escaping_path_is_refused_as_a_catalog_defect(self):
        # Mandate §4 case 6's other half. A catalog file path is joined onto the
        # resolved model root, so `../` makes every size and digest check run on
        # a *different* file than the one the loader later opens — the pins would
        # be true of the wrong bytes. `resolve_model_root` guards the id and the
        # version directory; nothing guarded the per-file paths.
        escaping = ("../../etc/passwd", "../outside.bin", "/etc/passwd",
                    "vae/../../secret", "", "a\x00b", ".hidden/x")
        for path in escaping:
            with self.subTest(path=path):
                bad = ModelEntry(
                    id="escape", name="Escape", task="upscaling",
                    license_id="MIT", permitted_use=CLEARED_USE, source="local",
                    files=(ModelFile(path, SHA_OF_WEIGHTS, len(WEIGHTS)),))
                self.assertEqual(pin_problem(bad)[:2],
                                 ("unsafe-path", path))
                folder = self.root / bad.id
                folder.mkdir(exist_ok=True)
                (folder / "weights.bin").write_bytes(WEIGHTS)
                catalog = Catalog(self.root, allow_uncleared=False)
                with _with(bad):
                    for accessor in (catalog.require, catalog.require_verified):
                        with self.subTest(accessor=accessor.__name__):
                            with self.assertRaises(WorkerError) as caught:
                                accessor(bad.id)
                self.assertEqual(caught.exception.code, CATALOG_INVALID)
                self.assertEqual(caught.exception.data["reason"], "unsafe-path")
                self.assertEqual(catalog._leases, {})

    def test_nested_catalog_paths_stay_legal(self):
        # `flux2` really does pin `vae/0.safetensors`, so a nested path must keep
        # passing admission or the fix would strand a shipped model.
        nested = ModelEntry(
            id="nested", name="Nested", task="upscaling", license_id="MIT",
            permitted_use=CLEARED_USE, source="local",
            files=(ModelFile("vae/0.safetensors", SHA_OF_WEIGHTS, len(WEIGHTS)),))
        self.assertIsNone(pin_problem(nested))

    def test_a_symlinked_weight_is_refused_rather_than_pinned_to_other_bytes(self):
        # Attempted bypass of the digest gate by substituting a link: the pins are
        # checked against the target's bytes, while a runtime that reopens by
        # name can be redirected between the two operations. A store entry has to
        # be a regular file inside its own install.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "weights.bin").write_bytes(WEIGHTS)   # the correct digest
        os.symlink(elsewhere / "weights.bin", folder / "weights.bin")
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            for accessor in (catalog.require, catalog.require_verified):
                with self.subTest(accessor=accessor.__name__):
                    with self.assertRaises(WorkerError) as caught:
                        accessor(VERIFIED.id)
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(caught.exception.data["reason"], "unsafe-path")
        self.assertEqual(catalog._leases, {})

    def test_a_payload_the_catalog_does_not_name_is_refused_at_load(self):
        # Attempted bypass by *addition* rather than substitution. The digest pass
        # only reads names the catalog carries, so the old gate was blind to a file
        # nobody listed. That blind spot is exploitable with the loaders shipped
        # here: `transformers` chooses a checkpoint by convention and prefers
        # `model.safetensors` over a pinned `pytorch_model.bin` in the same
        # directory, so one dropped file swaps the weights a job runs on while
        # every pin in the catalog still reads correct.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)          # the honest, pinned bytes
        (folder / "model.safetensors").write_bytes(b"OTHER")   # what a loader would pick
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            for accessor in (catalog.require, catalog.require_verified):
                with self.subTest(accessor=accessor.__name__):
                    with self.assertRaises(WorkerError) as caught:
                        accessor(VERIFIED.id)
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(caught.exception.data["reason"], "unlisted-file")
        self.assertEqual(caught.exception.data["files"], ["model.safetensors"])
        # A refusal is not a load: nothing may be left leased behind it.
        self.assertEqual(catalog._leases, {})

    def test_nested_and_hidden_additions_are_named_by_the_refusal(self):
        # The net is a recursive listing, not a scan of the top layer, and the
        # message carries the relative names so a user can delete what landed there.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        (folder / "vae").mkdir()
        (folder / "vae" / "extra.bin").write_bytes(b"x")
        (folder / ".hidden").write_bytes(b"x")
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            with self.assertRaises(WorkerError) as caught:
                catalog.require(VERIFIED.id)
        self.assertEqual(caught.exception.data["files"], [".hidden", "vae/extra.bin"])

    def test_a_link_inside_the_install_is_caught_even_when_it_hashes_clean(self):
        # A link the catalog does not name must not become an exception to the rule
        # just because its target's bytes are honest: the pin describes this path,
        # and a path that resolves outside the install is not this path.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "other.bin").write_bytes(b"OTHER")
        os.symlink(elsewhere / "other.bin", folder / "other.bin")
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
        self.assertEqual(caught.exception.data["reason"], "unlisted-file")
        self.assertEqual(caught.exception.data["files"], ["other.bin"])

    def test_a_linked_directory_is_named_rather_than_walked(self):
        # A linked *directory* is the one shape where the previous net could defer
        # to a library: `Path.rglob` decides for itself whether a link is part of
        # the tree it lists. That decision cannot be the policy, because the whole
        # point of the net is to refuse bytes the record cannot name — and a link
        # into a directory holding `model.safetensors` is precisely how a loader
        # that resolves checkpoints by convention ends up on unpinned weights.
        # The link is therefore the thing reported, never entered.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        outside = self.root.parent / "outside-the-lease"
        outside.mkdir(exist_ok=True)
        (outside / "model.safetensors").write_bytes(b"OTHER")
        os.symlink(outside, folder / "vae")
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            with self.assertRaises(WorkerError) as caught:
                catalog.require(VERIFIED.id)
        data = caught.exception.data
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(data["reason"], "unlisted-file")
        self.assertEqual(data["files"], ["vae/"], data)
        # The refusal names a location inside the install and nothing else: these
        # strings travel to the host, where a UI or a log may print them, so an
        # absolute target would disclose the owner's filesystem in an error whose
        # only job is to say "unrecognised bytes are in this install".
        for name in data["files"]:
            self.assertFalse(name.startswith("/"), name)
            self.assertNotIn(str(outside), name)
            self.assertNotIn("..", Path(name).parts)

    def test_the_digest_pass_reads_bytes_only_while_the_lease_is_held(self):
        # A checksum is a statement about a tree, and the lease is what keeps the
        # tree still long enough for the statement to mean something. The check
        # exists as a comment in `_resolve_under_lease`; comments do not fail, so
        # pin it at the only line where it could actually be violated — the read.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        observed = []
        real_hash = catalog_module._sha256

        def watch(target):
            observed.append((Path(target).name, dict(catalog._leases)))
            return real_hash(target)

        with _with(VERIFIED):
            with patch.object(catalog_module, "_sha256", watch):
                catalog.require_verified(VERIFIED.id)
        self.assertEqual([name for name, _ in observed], ["weights.bin"], observed)
        for name, leases in observed:
            self.assertTrue(leases, f"{name} was hashed with no lease held")
            self.assertEqual({key[0] for key in leases}, {VERIFIED.id}, leases)

    def test_store_housekeeping_beside_the_weights_is_not_called_payload(self):
        # The installer writes `manifest.json` into the version directory and macOS
        # drops `.DS_Store` in anything a Finder user opens. Refusing those would
        # make an honest install unloadable, so the exception is named rather than
        # widened into "ignore anything unrelated".
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        (folder / "manifest.json").write_text("{}", encoding="utf-8")
        (folder / ".DS_Store").write_bytes(b"\x00")
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            self.assertEqual(catalog.require_verified(VERIFIED.id), folder)

    def test_the_report_paths_refuse_what_the_loader_refuses(self):
        # Three surfaces answer "is this install trustworthy" — launch health,
        # `models verify`, and the load path. Each used to check only the names the
        # catalog gave it, so a symlinked weight or an added file read healthy,
        # verified clean and *then* failed at load. An honest model manager cannot
        # promise a load the worker will refuse, so all three carry the same two
        # refusals and agree on the reason code that says which one fired.
        for defect in ("symlink", "unlisted"):
            with self.subTest(defect=defect):
                # A private root per shape: both defects live in the same install
                # directory, and a fixture that leaked into the next iteration
                # would report the first shape's refusal twice.
                with tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    folder = root / VERIFIED.id
                    folder.mkdir()
                    if defect == "symlink":
                        elsewhere = root / "elsewhere"
                        elsewhere.mkdir()
                        (elsewhere / "weights.bin").write_bytes(WEIGHTS)  # honest bytes
                        os.symlink(elsewhere / "weights.bin", folder / "weights.bin")
                        reason = "unsafe-path"
                    else:
                        (folder / "weights.bin").write_bytes(WEIGHTS)
                        (folder / "lora.safetensors").write_bytes(b"X")
                        reason = "unlisted-file"
                    catalog = Catalog(root, allow_uncleared=False)
                    with _with(VERIFIED):
                        health = catalog.health()
                        verified = catalog.verify(VERIFIED.id)
                        with self.assertRaises(WorkerError) as caught:
                            catalog.require(VERIFIED.id)
                state = {m["model"]: m for m in health["models"]}[VERIFIED.id]
                self.assertFalse(health["ok"], health)
                self.assertEqual([p["reason"] for p in state["problems"]], [reason])
                self.assertFalse(verified["ok"], verified)
                self.assertEqual([f["reason"] for f in verified["failed"]], [reason])
                self.assertEqual(caught.exception.data["reason"], reason)

    def test_health_never_reports_a_payload_only_install_as_clean(self):
        # `health()` is the launch gate, and it is the only check a start gets when
        # nobody opens the model manager. The size loop passes when the pinned file
        # is intact, so without the payload net a launch would report `ok` over an
        # install that refuses every job.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        (folder / "extra.bin").write_bytes(b"X")
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            self.assertFalse(catalog.health()["ok"])
            (folder / "extra.bin").unlink()
            self.assertTrue(catalog.health()["ok"])

    def test_no_accessor_returns_a_path_without_hashing_when_a_digest_is_recorded(self):
        # Structural proof that there is no way back to the old behaviour: the
        # digest loop cannot be skipped by a null pin, because the only skip
        # branch in `_verify_digests` is the cache hit, and admission guarantees
        # every recorded digest normalises to 64 hex characters.
        source = Path(catalog_module.__file__).read_text("utf-8")
        body = source[source.index("def _verify_digests"):source.index("def require_verified")]
        self.assertNotIn("is None:\n                continue", body,
                         "_verify_digests skips a file instead of hashing it")
        self.assertIn("self._proofs[key] = (generation, expected)", body,
                      "the memo write disappeared, so a cache hit could be forged")
        # The cache is written only after a real hash matched.
        self.assertLess(body.index("actual = _sha256(target)"),
                        body.index("self._proofs[key] ="))
        self.assertLess(body.index("if actual != expected:"),
                        body.index("self._proofs[key] ="))

    def test_a_proof_cannot_be_seeded_from_outside_a_hash(self):
        # Attempted bypass of the cache: pre-populate `_proofs` with what looks
        # like a verified record for tampered bytes and confirm the load still
        # hashes. The key includes ctime and the catalog generation, and a caller
        # that does not know them cannot produce a hit.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        target = folder / "weights.bin"
        target.write_bytes(b"TAMPRED")     # right length, wrong content
        catalog = Catalog(self.root, allow_uncleared=False)
        stamp = target.stat()
        guesses = [
            (catalog.root, VERIFIED.id, "weights.bin", SHA_OF_WEIGHTS,
             len(WEIGHTS), stamp.st_dev, stamp.st_ino, stamp.st_size,
             stamp.st_mtime_ns),
            (str(catalog.root), VERIFIED.id, "weights.bin", SHA_OF_WEIGHTS,
             len(WEIGHTS)),
            (VERIFIED.id, "weights.bin", SHA_OF_WEIGHTS),
        ]
        for key in guesses:
            catalog._proofs[key] = (catalog._generation(), SHA_OF_WEIGHTS)
        with _with(VERIFIED):
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(caught.exception.data["reason"], "digest")

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

    def test_a_cached_proof_never_crosses_a_process_boundary(self):
        # The cache is the one part of this design an attacker only has to wait
        # for, so its blast radius is pinned: it lives in the Catalog instance and
        # nothing about it is written to disk. A second process - a fresh worker,
        # or the `models verify` subprocess - must hash the same bytes again, even
        # though it stats the very same inode the first one proved.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        (folder / "weights.bin").write_bytes(WEIGHTS)
        first = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            first.require_verified(VERIFIED.id)
        self.assertEqual(len(first._proofs), 1)

        probe = PROBE_TEMPLATE % (str(WORKER_DIR), str(self.root))
        result = subprocess.run([sys.executable, "-c", probe], capture_output=True,
                                text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["proofs"], 0)
        # And nothing under the model root could have carried it: `.locks` holds
        # lease files, which are empty advisory locks and never a digest.
        self.assertEqual(sorted(path.name for path in self.root.iterdir()
                                if path.name.startswith(".")), [".locks"])
        for lock in (self.root / ".locks").iterdir():
            self.assertEqual(lock.stat().st_size, 0,
                             "a lease file grew content that another process "
                             "could read as a verification result")

    def test_a_replaced_file_with_a_forged_mtime_is_still_rehashed(self):
        # Attempted bypass of the cache by the cheapest means available: write
        # tampered bytes, then restore the modification time the honest file had.
        # Length and mtime alone would read as "the same artifact I already
        # verified"; ctime cannot be forged from userspace without extra
        # privileges, and every write moves it.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        target = folder / "weights.bin"
        target.write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            catalog.require_verified(VERIFIED.id)
            self.assertEqual(len(catalog._proofs), 1)
            stamp = target.stat()
            target.write_bytes(b"TAMPRED")               # same length, wrong bytes
            os.utime(target, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
            self.assertEqual(target.stat().st_mtime_ns, stamp.st_mtime_ns)
            self.assertNotEqual(target.stat().st_ctime_ns, stamp.st_ctime_ns)
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(caught.exception.data["reason"], "digest")

    def test_the_same_bytes_replaced_by_a_new_inode_are_rehashed(self):
        # Attempted bypass by renaming a good file away and a bad one in: the
        # inode changes, so the proof key changes, whatever the names do.
        folder = self.root / VERIFIED.id
        folder.mkdir()
        target = folder / "weights.bin"
        target.write_bytes(WEIGHTS)
        catalog = Catalog(self.root, allow_uncleared=False)
        with _with(VERIFIED):
            catalog.require_verified(VERIFIED.id)
            # The keeper goes outside the install on purpose. A file left inside
            # it is now refused on its own by the unlisted-payload net, which would
            # mask the inode change this test exists to exercise.
            keeper = self.root / "keeper.bin"
            os.replace(target, keeper)                   # keeps the proven inode
            target.write_bytes(b"TAMPRED")               # fresh inode, same name
            self.assertEqual(len(catalog._proofs), 1)
            with self.assertRaises(WorkerError) as caught:
                catalog.require_verified(VERIFIED.id)
        self.assertEqual(caught.exception.data["reason"], "digest")

    def test_every_entry_has_a_license_id(self):
        for entry in CATALOG:
            self.assertTrue(entry.license_id, entry.id)
            if entry.permitted_use.weights.verdict == APPROVED:
                self.assertIn(entry.license_id, {"Apache-2.0", "MIT", "BSD-3-Clause"},
                              f"{entry.id} claims its weights are approved")


if __name__ == "__main__":
    unittest.main()
