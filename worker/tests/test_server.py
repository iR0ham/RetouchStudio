import hashlib
import json
import shutil
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock
from unittest.mock import patch

from retouch_ai_worker.catalog import (Catalog, ModelEntry, ModelFile,
                                       STATED_BY_NOT_ESTABLISHED, UNKNOWN)
from retouch_ai_worker.capabilities import (BLOCKED, PROVIDER, SUPPORTED, VOCABULARY,
                                            current_platform)
from retouch_ai_worker.protocol import (BUSY, CATALOG_INVALID, CHECKSUM_MISMATCH,
                                        INVALID_PARAMS, LICENSE_BLOCKED,
                                        MODEL_MISSING, PATH_DENIED, UNSUPPORTED,
                                        WorkerError, decode, encode)
from retouch_ai_worker.server import (JOB_LOCK_NAME, JobManager,
                                      acquire_folder_lock, WorkerServer)
from retouch_ai_worker.transport import read_image



def cleared_use():
    """A complete, admitted licence record for a synthetic fixture entry.

    These fixtures were written when an entry's permission answer was one
    boolean. The record replaced that boolean, so a synthetic entry now needs a
    real record; taking a shipped entry that is admitted by its own record keeps
    the fixture honest about the shape `validate()` enforces instead of inventing
    one per test.

    It deliberately does *not* take `SHIPPED[0]` any more: after S-FLUX the FLUX
    row is UNKNOWN, so position zero would hand every "a correctly pinned model
    runs" fixture a licence refusal and the integrity tests below would prove
    nothing. `migan` is admitted, and its weights are 8-byte test fixtures the
    size-only accessor accepts either way.
    """
    from retouch_ai_worker.catalog import CATALOG as SHIPPED
    return next(entry.permitted_use for entry in SHIPPED
                if entry.id == "migan" and entry.permitted_use.admitted)


def uncleared_use():
    """The same record with its weights permission withdrawn, so it refuses."""
    from dataclasses import replace as dc_replace
    use = cleared_use()
    return dc_replace(use, weights=dc_replace(
        use.weights, can_acquire=None, can_redistribute=None, can_use=None,
        stated_by=STATED_BY_NOT_ESTABLISHED, verdict=UNKNOWN,
        note="no rights-holder statement was found"))


class FakeEngine:
    """Same contract as Engine.run, without any model."""

    def run(self, kind, params, ctx):
        if kind == "ping":
            return {"pong": True}
        if kind == "slow":
            ticks = int(params.get("ticks", 100))
            for _ in range(ticks):
                ctx.check_cancel()
                ctx.emit("tick", tick=_)
                time.sleep(0.02)
            return {"finished": True}
        if kind == "boom":
            raise WorkerError(-32602, "bad input", {"field": "prompt"})
        if kind == "patch_edit":
            # Enough of the real job to see where each envelope name lands: the
            # gate reaches the context as `capability_id`, the A1 label as
            # `requested_capability`, and the two are not the same thing.
            return {"capability": ctx.capability_id,
                    "requested": ctx.requested_capability}
        raise WorkerError(-32601, f"no such kind {kind}")

    def execution_providers(self):
        # No loader has run here, which is exactly what the real engine says
        # before the first job.
        return [], "no model has been loaded, so no execution provider has initialised"


class ModelEngine:
    """A job that resolves its weights through the catalog, like Engine does."""

    def __init__(self, catalog):
        self.catalog = catalog
        self.providers = []

    def run(self, kind, params, ctx):
        if kind == "upscale":
            return {"root": str(self.catalog.require("swin2sr-x4"))}
        if kind == "inpaint":
            # The `migan` loader's shape: resolve the weights through the
            # catalog and hand the bytes to a runtime. Integrity refusals have
            # to surface from here, which is why this fake exists.
            return {"root": str(self.catalog.require_verified("migan"))}
        raise WorkerError(-32601, f"no such kind {kind}")

    def execution_providers(self):
        if self.providers:
            return list(self.providers), None
        return [], "no model has been loaded, so no execution provider has initialised"


class Session:
    def __init__(self, path: Path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(str(path))
        self.buffer = b""
        self.next_id = 0

    def send(self, method, params=None):
        self.next_id += 1
        self.sock.sendall(encode({"jsonrpc": "2.0", "id": self.next_id,
                                  "method": method, "params": params or {}}))
        return self.next_id

    def read_message(self):
        while b"\n" not in self.buffer:
            block = self.sock.recv(65536)
            if not block:
                raise EOFError
            self.buffer += block
        line, self.buffer = self.buffer.split(b"\n", 1)
        return decode(line)

    def call(self, method, params=None):
        request_id = self.send(method, params)
        while True:
            message = self.read_message()
            if message.get("id") == request_id:
                return message

    def close(self):
        self.sock.close()


LOCK_PROBE = """
import fcntl, os, sys
handle = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    raise SystemExit(3)
raise SystemExit(0)
"""


def _repin(entry, defect):
    """A copy of a shipped entry with one catalog defect injected.

    `migan` pins one file and the upscaler three, so the fixtures stay honest
    about a real entry's shape instead of a single-file toy: only the named
    defect changes.
    """
    if defect == "missing-digest":
        files = tuple(ModelFile(spec.path, None, spec.bytes, spec.url)
                      for spec in entry.files)
    elif defect == "missing-size":
        files = tuple(ModelFile(spec.path, spec.sha256, None, spec.url)
                      for spec in entry.files)
    elif defect == "invalid-digest":
        files = tuple(ModelFile(spec.path, "deadbeef", spec.bytes, spec.url)
                      for spec in entry.files)
    elif defect == "unsafe-path":
        files = tuple(ModelFile("../" + spec.path.replace("/", "_"),
                                spec.sha256, spec.bytes, spec.url)
                      for spec in entry.files)
    elif defect == "complete":
        return entry
    else:
        raise AssertionError(f"unknown defect {defect!r}")
    return ModelEntry(id=entry.id, name=entry.name, task=entry.task,
                      license_id=entry.license_id, permitted_use=entry.permitted_use,
                      source=entry.source, files=files, notes=entry.notes)


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "inputs").mkdir()
        catalog = Catalog(root / "models", allow_uncleared=False)
        self.manager = JobManager(FakeEngine(), root / "jobs", (root / "inputs",))
        self.server = WorkerServer(root / "worker.sock", self.manager, catalog,
                                   (root / "inputs",),
                                   helper_generation="11111111-1111-4111-8111-111111111111",
                                   launch_nonce="22222222-2222-4222-8222-222222222222")
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.session = Session(root / "worker.sock")

    def tearDown(self):
        self.session.close()
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def use_shipping_catalog(self) -> Catalog:
        """Swap in the production catalogue, with no evaluation switch.

        Every shipped entry is admitted by its own permitted-use record since the
        release manager's 2026-11-22 decision, taken under the owner's standing
        execution mandate, so the runtime paths below (size check,
        legacy install, the kind-only escape hatch, a recorded run) are reached
        through `allow_uncleared=False` — the gate they actually cross in the
        app. `RETOUCH_AI_EVAL_MODELS=1` still exists for a model the shipping
        table refuses; it is simply no longer what makes these tests pass, and
        keeping it here would hide a licence regression behind a switch. The
        refusal branch itself is pinned against a table that really refuses, in
        `test_job_submit_refuses_an_unlicensed_capability`.
        """
        catalog = Catalog(self.server.catalog.root, allow_uncleared=False)
        self.server.catalog = catalog
        return catalog

    def test_the_shipped_flux_record_refuses_every_surface_over_rpc(self):
        # S-FLUX end-to-end, on the shipping table with no evaluation switch and
        # no fixture: the four host-facing surfaces must all answer with the
        # licence class, because a refusal that raises in `catalog.py` and arrives
        # as something else is still fail-open for the user.
        catalog = self.use_shipping_catalog()

        plan = self.session.call("models.plan", {"models": ["flux2-klein-4b-q4"]})
        self.assertEqual(plan["error"]["code"], LICENSE_BLOCKED)
        self.assertEqual(plan["error"]["data"]["verdict"], "unknown")
        self.assertEqual(plan["error"]["data"]["artefact"], "weights")

        # `models.verify` is the health report, not a load path: it never consults
        # the licence record, so an uninstalled flux still reports `ok: false` with
        # a per-file `missing` problem rather than `-32010`. The licence refusal is
        # pinned on the two surfaces that do gate — `models.plan` and the loader.
        verify = self.session.call("models.verify", {"model": "flux2-klein-4b-q4"})
        self.assertNotIn("error", verify)
        self.assertFalse(verify["result"]["ok"])
        self.assertEqual({item["reason"] for item in verify["result"]["failed"]},
                         {"missing"})

        listed = {item["id"]: item for item in
                  self.session.call("models.list")["result"]["models"]}
        flux = listed["flux2-klein-4b-q4"]["permitted_use"]
        self.assertFalse(flux["admitted"])
        self.assertEqual(flux["weights"]["verdict"], "unknown")
        self.assertIsNone(flux["weights"]["canUse"])

        capabilities = {item["capabilityId"]: item for item in
                        self.session.call("capability.list")["result"]["capabilities"]}
        for capability in ("generative.edit", "generative.reimagine", "inpaint.object"):
            with self.subTest(capability=capability):
                record = capabilities[capability]
                # `blocked`, never `requires_model`: a download offer would tell
                # the user the weights are the only thing missing.
                self.assertEqual(record["state"], BLOCKED)
                self.assertIn("no established permission", record["reason"])
                self.assertIn("weights verdict: unknown", record["reason"])
                reply = self.session.call("job.submit", {
                    "kind": "patch_edit", "capabilityId": capability, "params": {}})
                self.assertEqual(reply["error"]["code"], UNSUPPORTED)
                self.assertEqual(reply["error"]["data"]["state"], BLOCKED)
                self.assertIn("no established permission", reply["error"]["message"])
        self.assertEqual(catalog._leases, {})

    def test_hello(self):
        reply = self.session.call("hello")
        self.assertEqual(reply["result"]["protocol"], "2")
        self.assertEqual(reply["result"]["protocol_version"], 2)
        self.assertEqual(reply["result"]["helper_generation"],
                         self.server.helper_generation)
        self.assertEqual(reply["result"]["launch_nonce"], self.server.launch_nonce)
        self.assertEqual(reply["contractVersion"], "1")

    def test_models_list_carries_the_permitted_use_record(self):
        models = self.session.call("models.list")["result"]["models"]
        by_id = {model["id"]: model for model in models}
        self.assertEqual(by_id["swin2sr-x4"]["license"], "Apache-2.0")
        self.assertNotIn("commercial_ok", by_id["swin2sr-x4"])
        record = by_id["swin2sr-x4"]["permitted_use"]
        self.assertEqual(set(record),
                         {"code", "weights", "trainingData", "admitted"})
        self.assertEqual(
            set(record["weights"]),
            {"use", "canAcquire", "canRedistribute", "canUse", "statedBy",
             "evidenceUrl", "readOn", "verdict", "conditions", "notice", "note"})
        # swin2sr's weights grant is a rights-holder statement carried by that
        # lab's own verified Hugging Face organisation, approved with four met
        # conditions on 2026-11-22 (Docs/MODEL_LICENCES.md §8), so `models.list`
        # reports the model as admitted.
        self.assertTrue(record["admitted"])
        self.assertEqual(record["weights"]["statedBy"], "rights-holder")
        self.assertEqual(record["weights"]["verdict"], "approved-with-conditions")
        self.assertIs(record["weights"]["canUse"], True)
        self.assertTrue(record["weights"]["conditions"])
        self.assertTrue(all(item["met"] for item in record["weights"]["conditions"]))
        # The training-data axis stays unknown: the addendum records the
        # DIV2K/Flickr2K quote without claiming the per-checkpoint mix.
        self.assertEqual(record["trainingData"]["verdict"], "unknown")
        self.assertIsNone(record["trainingData"]["canUse"])
        self.assertEqual(
            record["weights"]["evidenceUrl"],
            "https://huggingface.co/caidas/swin2SR-realworld-sr-x4-64-bsrgan-psnr")
        # … and flux's weights permission is *not* established (S-FLUX, 2026-11-23:
        # the quoted Apache sentence belongs to `black-forest-labs/FLUX.2-klein-4B`,
        # not to the community conversion this entry downloads), so its record
        # refuses it and states no axis.
        flux = by_id["flux2-klein-4b-q4"]["permitted_use"]
        self.assertFalse(flux["admitted"])
        self.assertEqual(flux["weights"]["statedBy"], STATED_BY_NOT_ESTABLISHED)
        self.assertEqual(flux["weights"]["verdict"], UNKNOWN)
        self.assertIsNone(flux["weights"]["canUse"])
        # … and every shipped entry carries a complete record, not a boolean.
        for model in models:
            self.assertIn("permitted_use", model)
            self.assertNotIn("commercial_ok", model)

    def test_health_reports_missing_models_without_failing(self):
        reply = self.session.call("health")["result"]
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["protocol"], "2")
        self.assertEqual(reply["protocol_version"], 2)
        self.assertEqual(reply["helper_generation"], self.server.helper_generation)
        self.assertEqual(reply["launch_nonce"], self.server.launch_nonce)
        self.assertEqual(reply["pid"], os.getpid())
        self.assertTrue(reply["models"])
        self.assertFalse(any(model["installed"] for model in reply["models"]))

    def test_provider_list_reports_nothing_before_a_model_runs(self):
        reply = self.session.call("provider.list")["result"]
        self.assertEqual(reply["contractVersion"], "1")
        provider = reply["providers"][0]
        self.assertEqual(provider["id"], "macos-python")
        self.assertEqual(provider["state"], "unavailable")
        self.assertEqual(provider["execution_providers"], [])
        self.assertTrue(provider["reason"])

    def test_provider_list_reports_the_device_a_model_ran_on(self):
        # CPU was the wrong answer on this hardware: the provider the worker
        # names is the one a loader actually used.
        engine = ModelEngine(self.server.catalog)
        engine.providers = ["mps"]
        self.manager.engine = engine
        provider = self.session.call("provider.list")["result"]["providers"][0]
        self.assertEqual(provider["state"], "available")
        self.assertEqual(provider["execution_providers"], ["mps"])
        self.assertNotIn("reason", provider)

    def test_health_flags_a_truncated_installed_file(self):
        # A small, known model stands in for a damaged download: the size check
        # must catch it without hashing anything.
        root = self.server.catalog.root
        target = root / "migan" / "migan_pipeline_v2.onnx"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"not the real weights")
        try:
            reply = self.session.call("health")["result"]
        finally:
            target.unlink()
        self.assertFalse(reply["ok"])
        broken = {model["model"]: model for model in reply["models"]}["migan"]
        self.assertTrue(broken["installed"])
        self.assertFalse(broken["ok"])
        self.assertEqual(broken["problems"][0]["reason"], "size")

    def test_job_lifecycle(self):
        reply = self.session.call("job.submit", {"kind": "ping", "params": {}})
        self.assertIn("job_id", reply["result"])
        job_id = reply["result"]["job_id"]
        deadline = time.time() + 5
        while time.time() < deadline:
            status = self.session.call("job.status", {"job_id": job_id})["result"]
            if status["status"] == "succeeded":
                break
            time.sleep(0.02)
        self.assertEqual(status["status"], "succeeded")
        result = self.session.call("job.result", {"job_id": job_id})["result"]
        self.assertEqual(result["result"], {"pong": True})

    def test_progress_notifications_are_pushed(self):
        job_id = self.session.call("job.submit",
                                   {"kind": "slow", "params": {"ticks": 5}})["result"]["job_id"]
        events = []
        deadline = time.time() + 5
        while time.time() < deadline:
            message = self.session.read_message()
            if message.get("method"):
                events.append(message["method"])
            if message.get("method") == "job.finished":
                break
        self.assertIn("job.started", events)
        self.assertIn("job.progress", events)
        self.assertEqual(job_id, self.session.call("job.status", {"job_id": job_id})["result"]["job_id"])

    def test_second_job_is_rejected_while_busy(self):
        self.session.call("job.submit", {"kind": "slow", "params": {"ticks": 50}})
        reply = self.session.call("job.submit", {"kind": "ping", "params": {}})
        self.assertEqual(reply["error"]["code"], BUSY)

    def test_cancel_is_acknowledged_immediately(self):
        job_id = self.session.call("job.submit",
                                   {"kind": "slow", "params": {"ticks": 200}})["result"]["job_id"]
        time.sleep(0.1)
        started = time.perf_counter()
        ack = self.session.call("job.cancel", {"job_id": job_id})["result"]
        ack_seconds = time.perf_counter() - started
        self.assertTrue(ack["cancel_requested"])
        self.assertLess(ack_seconds, 0.5)

        deadline = time.time() + 3
        while time.time() < deadline:
            status = self.session.call("job.status", {"job_id": job_id})["result"]
            if status["status"] == "cancelled":
                break
            time.sleep(0.02)
        self.assertEqual(status["status"], "cancelled")
        result = self.session.call("job.result", {"job_id": job_id})["result"]
        self.assertEqual(result["error"]["code"], -32014)
        self.assertIsInstance(result["cancelLatencyMs"], (int, float))
        self.assertGreaterEqual(result["cancelLatencyMs"], 0)

    def stranger_claims(self, lock_file: Path) -> bool:
        """Ask a process the worker has never heard of to lock the folder.

        The sweep is the app's, not the worker's, so an in-process second
        descriptor proves less than a real child with its own kernel table.
        """
        probe = subprocess.run([sys.executable, "-c", LOCK_PROBE, str(lock_file)],
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(probe.returncode in (0, 3), True, probe.stderr)
        return probe.returncode == 0

    def test_a_running_job_claims_its_workdir_until_the_job_ends(self):
        # `<workdir>/.lock` is how a job says "the pixels here are being written".
        # The launch sweep in the app walks past a folder it cannot claim, so a
        # render that overruns the age bound still cannot be cleaned under.
        job_id = self.session.call("job.submit",
                                   {"kind": "slow", "params": {"ticks": 200}})["result"]["job_id"]
        workdir = Path(self.manager.jobs_root) / job_id
        lock_file = workdir / JOB_LOCK_NAME
        # Wait for the job to be observably running, not for `.lock` to appear:
        # `JobManager._run` opens the file and takes the flock before it writes
        # `status="running"`, so a running status means the lock is already
        # held. Waiting on the path instead races that open -> flock window,
        # where the file exists but nobody has locked it yet.
        deadline = time.time() + 5
        status = None
        while time.time() < deadline:
            status = self.session.call("job.status", {"job_id": job_id})["result"]
            if status["status"] == "running":
                break
            time.sleep(0.02)
        self.assertEqual(status["status"], "running",
                         "the job is observably running before its claim is probed")
        self.assertTrue(lock_file.exists(),
                        "the running job created the lock its workdir is claimed with")
        self.assertIsNone(acquire_folder_lock(workdir),
                          "a second claim on a running job's folder is refused")
        self.assertFalse(self.stranger_claims(lock_file),
                         "a process that never spoke to this worker is refused too")

        self.session.call("job.cancel", {"job_id": job_id})
        deadline = time.time() + 5
        while time.time() < deadline:
            status = self.session.call("job.status", {"job_id": job_id})["result"]
            if status["status"] == "cancelled":
                break
            time.sleep(0.02)
        self.assertEqual(status["status"], "cancelled")

        # The claim belongs to the job, not to the process: once the render is
        # over the folder is ordinary residue, which is what the sweep needs.
        free = False
        deadline = time.time() + 5
        while time.time() < deadline and not free:
            claim = acquire_folder_lock(workdir)
            if claim is None:
                time.sleep(0.02)
                continue
            os.close(claim)
            free = True
        self.assertTrue(free, "the finished job lets go of its folder")
        self.assertTrue(self.stranger_claims(lock_file),
                        "the lock file stays put and is simply free to take")

    def test_capability_list_reports_the_frozen_vocabulary(self):
        reply = self.session.call("capability.list")["result"]
        self.assertEqual(reply["contractVersion"], "1")
        self.assertEqual(reply["vocabulary"], VOCABULARY)
        self.assertEqual(reply["provider"], PROVIDER)
        records = {item["capabilityId"]: item for item in reply["capabilities"]}
        self.assertEqual(len(records), 16)
        for item in records.values():
            if item["state"] != "supported":
                self.assertTrue(item["reason"], item)
        # swin2sr's weights record is admitted (the release manager's
        # 2026-11-22 decision under the owner's execution mandate), so
        # nothing installed means the honest download offer here — the same shape
        # `inpaint.spot` reports two lines below. The licence refusal that used to
        # win this comparison is pinned with a table that really refuses, in
        # `test_job_submit_refuses_an_unlicensed_capability`.
        upscale = records["upscale.4x"]
        self.assertEqual(upscale["state"], "requires_model")
        self.assertIn("not installed", upscale["reason"])
        self.assertNotIn("no established permission", upscale["reason"])
        self.assertEqual(records["inpaint.spot"]["state"], "requires_model")

    def test_capability_list_marks_the_recorded_upscale_run_supported(self):
        catalog = self.use_shipping_catalog()
        root = catalog.root
        version = root / "swin2sr-x4" / "1.0.0"
        version.mkdir(parents=True)
        for name, size in (("config.json", 772), ("preprocessor_config.json", 152),
                           ("pytorch_model.bin", 48_460_141)):
            with (version / name).open("wb") as handle:
                handle.truncate(size)
        (root / "swin2sr-x4" / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": "swin2sr-x4", "version": "1.0.0",
        }))
        reply = self.session.call("capability.list")["result"]
        records = {item["capabilityId"]: item for item in reply["capabilities"]}
        upscale = records["upscale.4x"]
        self.assertEqual(upscale["state"], "supported")
        self.assertEqual(upscale["modelVersion"], "1.0.0")
        self.assertIn("PHASE5_ACCEPTANCE", upscale["evidence"])

    def test_job_submit_refuses_a_blocked_capability(self):
        reply = self.session.call("job.submit", {
            "kind": "patch_edit", "capabilityId": "generative.outpaint",
            "params": {}})
        self.assertEqual(reply["error"]["code"], UNSUPPORTED)
        self.assertEqual(reply["error"]["data"]["capabilityId"],
                         "generative.outpaint")

    def test_job_submit_refuses_an_unlicensed_capability(self):
        # The licence gate is still a gate. No shipped entry fails it today, so
        # the branch is exercised with a table whose swin2sr weights record says
        # `unknown` with blank axes — exactly the shape that would come back if
        # someone lowered the grant again — and an install that would otherwise
        # be supported. A refusal must arrive as `blocked`, never as a download
        # offer and never as a submitted job.
        from dataclasses import replace as dc_replace

        from retouch_ai_worker.catalog import CATALOG as SHIPPED
        from retouch_ai_worker.catalog import UNKNOWN, ArtefactTerms

        unestablished = dc_replace(
            SHIPPED[0].permitted_use.weights,
            verdict=UNKNOWN, stated_by="not-established", can_acquire=None,
            can_redistribute=None, can_use=None, conditions=(),
            note="pinned for this test: the search produced no statement")
        refusing = tuple(
            dc_replace(entry,
                       permitted_use=dc_replace(entry.permitted_use,
                                                weights=unestablished))
            if entry.id == "swin2sr-x4" else entry
            for entry in SHIPPED)
        catalog = self.use_shipping_catalog()
        version = catalog.root / "swin2sr-x4" / "1.0.0"
        version.mkdir(parents=True)
        for name, size in (("config.json", 772), ("preprocessor_config.json", 152),
                           ("pytorch_model.bin", 48_460_141)):
            with (version / name).open("wb") as handle:
                handle.truncate(size)
        (catalog.root / "swin2sr-x4" / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": "swin2sr-x4", "version": "1.0.0",
        }), encoding="utf-8")
        self.assertIsInstance(unestablished, ArtefactTerms)

        with mock.patch("retouch_ai_worker.catalog.CATALOG", refusing):
            reply = self.session.call("job.submit", {
                "kind": "upscale", "capabilityId": "upscale.4x", "params": {}})
            listed = {item["capabilityId"]: item for item in
                      self.session.call("capability.list")["result"]["capabilities"]}
        self.assertEqual(reply["error"]["code"], UNSUPPORTED)
        self.assertEqual(reply["error"]["data"]["capabilityId"], "upscale.4x")
        self.assertEqual(reply["error"]["data"]["state"], BLOCKED)
        self.assertIn("no established permission", reply["error"]["message"])
        self.assertEqual(listed["upscale.4x"]["state"], BLOCKED)
        self.assertIn("no established permission", listed["upscale.4x"]["reason"])
        # And the refusal costs nothing: no job folder, no job record.
        self.assertEqual(sorted(os.listdir(Path(self.tmp.name) / "jobs"))
                         if (Path(self.tmp.name) / "jobs").exists() else [], [])

    def test_job_submit_refuses_a_mismatched_capability(self):
        reply = self.session.call("job.submit", {
            "kind": "patch_edit", "capabilityId": "upscale.4x", "params": {}})
        self.assertEqual(reply["error"]["code"], UNSUPPORTED)

    def test_job_submit_admits_a_capability_this_adapter_proves(self):
        # The refusals above only mean something if the gate still admits what
        # it legitimately reports. The macOS host now names `upscale.4x` on
        # every upscale pass (W5-4), so a gate that refused a supported install
        # would make the feature unreachable, and no refusal test would notice.
        # The evidence ledger here is a fixture naming whatever platform this
        # process reports, so the answer does not depend on the runner's arch.
        # The model runs under the evaluation switch: this test is about the
        # supported/refused boundary, not about the licence verdict for the
        # weights, which `test_models_list_*` pins separately.
        catalog = self.use_shipping_catalog()
        entry = catalog.get("swin2sr-x4")
        version = catalog.root / entry.id / "1.0.0"
        version.mkdir(parents=True)
        for spec in entry.files:
            target = version / spec.path
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("wb") as handle:
                handle.truncate(spec.bytes)
        (catalog.root / entry.id / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": entry.id, "version": "1.0.0",
        }), encoding="utf-8")
        ledger = Path(self.tmp.name) / "evidence.json"
        ledger.write_text(json.dumps({
            "schema": "retouchstudio.capability-evidence/1",
            "entries": [{"capabilityId": "upscale.4x",
                         "platform": current_platform(), "provider": PROVIDER,
                         "modelId": entry.id, "modelVersion": "1.0.0",
                         "evidence": "a recorded run, named by this fixture"}],
        }), encoding="utf-8")

        with mock.patch.dict(os.environ,
                             {"RETOUCH_AI_CAPABILITY_EVIDENCE": str(ledger)}):
            reported = {item["capabilityId"]: item for item in
                        self.session.call("capability.list")["result"]["capabilities"]}
            self.assertEqual(reported["upscale.4x"]["state"], SUPPORTED,
                             reported["upscale.4x"].get("reason"))
            self.server._require_capability("upscale.4x", "upscale")

    def test_a_requested_capability_labels_a_record_without_gating_the_job(self):
        # The approved A1: an edit needs a capability name in its provenance, but
        # the name is the host's statement about which tool ran, not a worker
        # verdict. So the same string refuses the job as `capabilityId` — flux is
        # refused outright since S-FLUX — and starts it as `requestedCapability`.
        # Collapsing the two would refuse shipped Quick Edit tools whose models
        # carry no recorded run, which is the A2 decision the owner has not made.
        gated = self.session.call("job.submit", {
            "kind": "patch_edit", "capabilityId": "generative.reimagine",
            "params": {}})
        # This used to answer `-32011 MODEL_MISSING`, because flux was admitted on
        # licence and simply had no weights here. Its record now refuses it, so the
        # gate answers with the licence class — which is the whole point: a
        # download cannot repair a permission.
        self.assertEqual(gated["error"]["code"], UNSUPPORTED)
        self.assertEqual(gated["error"]["data"]["state"], BLOCKED)

        started = self.session.call("job.submit", {
            "kind": "patch_edit", "requestedCapability": "generative.reimagine",
            "params": {}})
        self.assertNotIn("error", started)
        job_id = started["result"]["job_id"]
        deadline = time.time() + 5
        while time.time() < deadline:
            status = self.session.call("job.status", {"job_id": job_id})["result"]
            if status["status"] in ("succeeded", "failed", "cancelled"):
                break
            time.sleep(0.02)
        self.assertEqual(status["status"], "succeeded", status)
        reply = self.session.call("job.result", {"job_id": job_id})["result"]
        self.assertEqual(reply["result"],
                         {"capability": None,
                          "requested": "generative.reimagine"})

    def test_a_requested_capability_must_belong_to_the_kind(self):
        # A label the kind cannot carry is a caller bug, not a capability claim,
        # so it is refused before any job exists.
        for kind, name in (("patch_edit", "upscale.4x"), ("upscale", "inpaint.spot")):
            reply = self.session.call("job.submit", {
                "kind": kind, "requestedCapability": name, "params": {}})
            self.assertEqual(reply["error"]["code"], INVALID_PARAMS, reply)
            self.assertEqual(reply["error"]["data"]["capabilityId"], name)
            self.assertEqual(reply["error"]["data"]["kind"], kind)

    def test_kind_only_submission_cannot_load_a_damaged_model(self):
        # A submit that names no capability still fails at load time when
        # capability.list reports the install blocked for a size mismatch;
        # naming the capability refuses earlier, with E_UNSUPPORTED. The macOS
        # host names it for `upscale`, but the kind path stays open because it
        # is how an installed model without a recorded support claim runs.
        root = Path(self.tmp.name)
        catalog = self.use_shipping_catalog()
        version = catalog.root / "swin2sr-x4" / "1.0.0"
        version.mkdir(parents=True)
        for name, size in (("config.json", 772), ("preprocessor_config.json", 152),
                           ("pytorch_model.bin", 48)):
            with (version / name).open("wb") as handle:
                handle.truncate(size)
        (catalog.root / "swin2sr-x4" / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": "swin2sr-x4", "version": "1.0.0",
        }), encoding="utf-8")
        reported = {item["capabilityId"]: item
                    for item in self.session.call("capability.list")["result"]["capabilities"]}
        self.assertEqual(reported["upscale.4x"]["state"], "blocked")
        self.assertIn("size check", reported["upscale.4x"]["reason"])

        manager = JobManager(ModelEngine(catalog), root / "jobs",
                             (root / "inputs",))
        server = WorkerServer(root / "model.sock", manager, catalog,
                              (root / "inputs",))
        thread = threading.Thread(target=server.serve_forever,
                                  kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        session = Session(root / "model.sock")
        try:
            job_id = session.call("job.submit",
                                  {"kind": "upscale", "params": {}})["result"]["job_id"]
            deadline = time.time() + 5
            while time.time() < deadline:
                status = session.call("job.status", {"job_id": job_id})["result"]
                if status["status"] in ("succeeded", "failed", "cancelled"):
                    break
                time.sleep(0.02)
            result = session.call("job.result", {"job_id": job_id})["result"]
        finally:
            session.close()
            server.shutdown()
            server.server_close()
        self.assertEqual(status["status"], "failed")
        self.assertEqual(result["error"]["code"], CHECKSUM_MISMATCH)
        self.assertEqual(result["error"]["data"]["model"], "swin2sr-x4")

    # --- integrity refusals over the wire ---------------------------------
    #
    # Mandate §4 asks for the *end-to-end* answer, not just the catalog's: a
    # rejection that raises the right `WorkerError` in `catalog.py` but arrives at
    # the host as `-32603 Internal error` (or, worse, as a succeeded job) is still
    # a fail-open from the user's point of view. Every test below drives a real
    # JSON-RPC connection — submit, run, poll, read `job.result` — against an
    # engine whose loader resolves its weights through the catalog exactly as the
    # shipped `_ensure_*` methods do.

    def _migan_entry(self, sha256, size=8):
        from retouch_ai_worker.catalog import ModelEntry, ModelFile

        return ModelEntry(id="migan", name="MI-GAN", task="inpainting",
                          license_id="MIT", permitted_use=cleared_use(), source="local",
                          files=(ModelFile("weights.bin", sha256, size),))

    def _install_migan(self, payload, versioned=True):
        """Put `payload` where the `migan` pin points, and return its folder."""
        root = self.server.catalog.root / "migan"
        folder = root / ("1.0.0" if versioned else "")
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "weights.bin").write_bytes(payload)
        if versioned:
            (root / "active.json").write_text(json.dumps({
                "schema": "retouchstudio.model-active/1",
                "modelId": "migan", "version": "1.0.0"}), encoding="utf-8")
        return folder

    def _run_kind_job(self, sock_name, kind="inpaint", capability=None,
                      manager=None):
        """Run one job to its terminal state over a real socket; return job.result.

        Naming no `capabilityId` is the shape the audit could not close: the
        server-side gate never runs, so the only thing standing between tampered
        bytes and a runtime is the loader's own verification. Passing one adds the
        other submission shape without duplicating the polling loop.
        """
        root = Path(self.tmp.name)
        if manager is None:
            manager = JobManager(ModelEngine(self.server.catalog),
                                 root / f"{sock_name}-jobs", (root / "inputs",))
        server = WorkerServer(root / f"{sock_name}.sock", manager, self.server.catalog,
                              (root / "inputs",))
        thread = threading.Thread(target=server.serve_forever,
                                  kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        session = Session(root / f"{sock_name}.sock")
        try:
            submit = {"kind": kind, "params": {}}
            if capability is not None:
                submit["capabilityId"] = capability
            sent = session.call("job.submit", submit)
            if "error" in sent:
                # The gate refused before a job existed: that refusal *is* the
                # answer, and it arrives as a plain JSON-RPC error object.
                return {"refused": sent["error"]}
            job_id = sent["result"]["job_id"]
            deadline = time.time() + 5
            status = None
            while time.time() < deadline:
                status = session.call("job.status", {"job_id": job_id})["result"]
                if status["status"] in ("succeeded", "failed", "cancelled"):
                    break
                time.sleep(0.02)
            reply = session.call("job.result", {"job_id": job_id})["result"]
        finally:
            session.close()
            server.shutdown()
            server.server_close()
        self.assertIn(status["status"], ("succeeded", "failed"), status)
        return reply

    def _run_kind_only_job(self, sock_name, kind="inpaint", manager=None):
        """A kind-only job that must fail; returns the failure it produced."""
        reply = self._run_kind_job(sock_name, kind, manager=manager)
        self.assertNotIn("refused", reply)
        self.assertIn("error", reply, reply)
        return reply["error"]

    def test_a_same_length_substitution_fails_the_job_over_rpc(self):
        # Measured on `cd5741b`: only the upscaler hashed at load, so a file with
        # the recorded length and the wrong content reached a runtime through a
        # kind-only submit.
        trusted = b"trusted!"
        pin = hashlib.sha256(trusted).hexdigest()
        self._install_migan(b"tampereD")                      # same length
        with patch("retouch_ai_worker.catalog.CATALOG", (self._migan_entry(pin),)):
            error = self._run_kind_only_job("tamper")
        self.assertEqual(error["code"], CHECKSUM_MISMATCH)
        self.assertEqual(error["data"]["model"], "migan")
        self.assertEqual(error["data"]["reason"], "digest")
        self.assertEqual(error["data"]["file"], "weights.bin")
        self.assertEqual(error["data"]["expected_sha256"], pin)
        self.assertEqual(error["data"]["actual_sha256"],
                         hashlib.sha256(b"tampereD").hexdigest())
        # The refused model is still repairable: nothing holds its lease.
        self.assertEqual(self.server.catalog._leases, {})

    def test_a_correctly_pinned_model_still_runs_over_rpc(self):
        # The positive control for every refusal above: a job whose bytes match
        # their pins must succeed through the same kind-only path, or the fix
        # would be a denial of service rather than a trust gate.
        good = b"trusted!"
        pin = hashlib.sha256(good).hexdigest()
        self._install_migan(good)
        with patch("retouch_ai_worker.catalog.CATALOG", (self._migan_entry(pin),)):
            reply = self._run_kind_job("pinned-ok")
        # The verified load returned the install path and the job ran: every
        # refusal above would have turned this into a failed job instead.
        self.assertIsNone(reply.get("error"), reply)
        self.assertEqual(reply["status"], "succeeded", reply)
        self.assertEqual(Path(reply["result"]["root"]).name, "1.0.0")

    def test_an_unverifiable_pin_refuses_the_kind_only_job(self):
        # The other half of admission over RPC: a null digest must fail the job
        # with `-32021`, not load the file the way `require_verified` used to.
        self._install_migan(b"tampereD")
        with patch("retouch_ai_worker.catalog.CATALOG", (self._migan_entry(None),)):
            error = self._run_kind_only_job("pin")
        self.assertEqual(error["code"], CATALOG_INVALID)
        self.assertEqual(error["data"]["reason"], "missing-digest")
        self.assertEqual(error["data"]["file"], "weights.bin")
        self.assertEqual(self.server.catalog._leases, {})

    def test_a_missing_size_refuses_the_kind_only_job(self):
        self._install_migan(b"trusted!")
        entry = self._migan_entry(hashlib.sha256(b"trusted!").hexdigest(), size=None)
        with patch("retouch_ai_worker.catalog.CATALOG", (entry,)):
            error = self._run_kind_only_job("nosize")
        self.assertEqual(error["code"], CATALOG_INVALID)
        self.assertEqual(error["data"]["reason"], "missing-size")

    def test_a_malformed_digest_refuses_the_kind_only_job(self):
        # A truncated pin can never equal hexdigest(). It used to be reported as
        # "failed its recorded checksum", which tells the user to repair weights
        # when the catalog is what is wrong.
        self._install_migan(b"trusted!")
        for pin, reason in (("g" * 64, "invalid-digest"),
                            ("abc", "invalid-digest"),
                            ("", "missing-digest")):
            with self.subTest(pin=repr(pin)):
                with patch("retouch_ai_worker.catalog.CATALOG",
                           (self._migan_entry(pin),)):
                    error = self._run_kind_only_job(f"bad-{len(pin)}-{reason}")
                self.assertEqual(error["code"], CATALOG_INVALID)
                self.assertEqual(error["data"]["reason"], reason)

    def test_an_uppercase_pin_loads_over_rpc(self):
        # Case is not a trust question. On the baseline this pin rejected a
        # byte-correct model forever, which is a denial the attacker does not even
        # have to cause.
        good = b"trusted!"
        upper = hashlib.sha256(good).hexdigest().upper()
        self._install_migan(good)
        with patch("retouch_ai_worker.catalog.CATALOG", (self._migan_entry(upper),)):
            reply = self._run_kind_job("upper")
        self.assertIsNone(reply.get("error"), reply)
        self.assertEqual(reply["status"], "succeeded", reply)

    def test_an_escaping_catalog_path_refuses_the_kind_only_job(self):
        # The pins would be checked against one file while the loader opens
        # another, so this is a trust defect and not a missing install.
        from retouch_ai_worker.catalog import ModelEntry, ModelFile

        folder = self._install_migan(b"trusted!")
        outside = self.server.catalog.root / "outside.bin"
        outside.write_bytes(b"trusted!")
        entry = ModelEntry(id="migan", name="MI-GAN", task="inpainting",
                           license_id="MIT", permitted_use=cleared_use(), source="local",
                           files=(ModelFile("../outside.bin",
                                            hashlib.sha256(b"trusted!").hexdigest(),
                                            8),))
        self.assertTrue(folder.exists())
        with patch("retouch_ai_worker.catalog.CATALOG", (entry,)):
            error = self._run_kind_only_job("escape")
        self.assertEqual(error["code"], CATALOG_INVALID)
        self.assertEqual(error["data"]["reason"], "unsafe-path")

    def test_a_symlinked_weight_refuses_the_kind_only_job(self):
        # Attempted bypass of the digest gate without editing any pin: point the
        # store file at bytes that happen to match, so the check passes on the
        # link target while a re-open by name can land elsewhere.
        self.server.catalog.root.mkdir(parents=True, exist_ok=True)
        real = self.server.catalog.root / "real.bin"
        real.write_bytes(b"trusted!")
        folder = self.server.catalog.root / "migan" / "1.0.0"
        folder.mkdir(parents=True)
        os.symlink(real, folder / "weights.bin")
        (self.server.catalog.root / "migan" / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": "migan", "version": "1.0.0"}), encoding="utf-8")
        entry = self._migan_entry(hashlib.sha256(b"trusted!").hexdigest())
        with patch("retouch_ai_worker.catalog.CATALOG", (entry,)):
            error = self._run_kind_only_job("symlink")
        self.assertEqual(error["code"], CHECKSUM_MISMATCH)
        self.assertEqual(error["data"]["reason"], "unsafe-path")

    def test_an_uncleared_model_refuses_the_kind_only_job_before_any_integrity(self):
        # Ordering, proven over the wire: a licence answer must not depend on disk
        # state, and an integrity answer must not be reachable by accepting the
        # licence. Here the bytes are perfectly valid and still refused.
        from retouch_ai_worker.catalog import ModelEntry, ModelFile

        good = b"trusted!"
        entry = ModelEntry(id="migan", name="MI-GAN", task="inpainting",
                           license_id="NOASSERTION", permitted_use=uncleared_use(),
                           source="local",
                           files=(ModelFile("weights.bin",
                                            hashlib.sha256(good).hexdigest(), 8),))
        self._install_migan(good)
        with patch("retouch_ai_worker.catalog.CATALOG", (entry,)):
            error = self._run_kind_only_job("licence")
        self.assertEqual(error["code"], LICENSE_BLOCKED)

        # A bad pin on an uncleared entry still answers with the licence first:
        # -32010 is the product decision, -32021 the technical one, and the
        # product one must not depend on what the catalog happens to record.
        pinless = ModelEntry(id="migan", name="MI-GAN", task="inpainting",
                             license_id="NOASSERTION", permitted_use=uncleared_use(),
                             source="local", files=(ModelFile("weights.bin", None, 8),))
        with patch("retouch_ai_worker.catalog.CATALOG", (pinless,)):
            error = self._run_kind_only_job("licence-pin")
        self.assertEqual(error["code"], LICENSE_BLOCKED)

        # ...and the research switch changes only that gate. It is read from the
        # environment when a Catalog is built without an explicit answer, which is
        # how `__main__` builds the worker's own, so the variable is set rather
        # than the constructor argument. Under it the same entry is refused for its
        # pin and never loaded. `AIWorker.swift` strips the variable from the
        # inherited environment, so a user's shell cannot reach this state in a
        # real launch (that half is NOT VERIFIED here: no app launch is permitted).
        root = Path(self.tmp.name)
        with mock.patch.dict(os.environ, {"RETOUCH_AI_EVAL_MODELS": "1"}):
            switched = JobManager(ModelEngine(Catalog(self.server.catalog.root)),
                                  root / "switch-jobs", (root / "inputs",))
        self.assertTrue(switched.engine.catalog.allow_uncleared)
        with patch("retouch_ai_worker.catalog.CATALOG", (pinless,)):
            error = self._run_kind_only_job("switch-pin", manager=switched)
        self.assertEqual(error["code"], CATALOG_INVALID)
        self.assertEqual(error["data"]["reason"], "missing-digest")

    def test_a_missing_model_stays_MODEL_MISSING_and_never_becomes_unverified(self):
        # Legitimate optional-model behaviour, kept across the tightening: nothing
        # installed is a downloadable answer, and no pin defect may masquerade as
        # one (the reverse mapping would offer a download that repairs nothing).
        entry = self._migan_entry(hashlib.sha256(b"trusted!").hexdigest())
        with patch("retouch_ai_worker.catalog.CATALOG", (entry,)):
            error = self._run_kind_only_job("absent")
        self.assertEqual(error["code"], MODEL_MISSING)
        self.assertEqual(error["data"]["reason"], "not-installed")
        self.assertEqual(error["data"]["missing"], "weights.bin")
        self.assertNotEqual(error["code"], CATALOG_INVALID)
        self.assertNotEqual(error["code"], CHECKSUM_MISMATCH)

    def test_a_named_capability_and_its_report_never_disagree(self):
        # The gate and the loader must not disagree, which is the half of the
        # taxonomy that used to be incoherent: `capability.list` called a pinless
        # entry unverifiable while `require_verified` loaded it. Both answers now
        # come from one admission rule, so a state the report can name is a state
        # the job path refuses the same way — for every model in the shipped
        # catalog, not just the one this branch happens to fake.
        from retouch_ai_worker.catalog import CATALOG as SHIPPED
        from retouch_ai_worker.catalog import ModelEntry, ModelFile

        states = {"missing-digest": "blocked", "missing-size": "blocked",
                  "invalid-digest": "blocked", "unsafe-path": "blocked",
                  None: "requires_model"}
        for defect in ("missing-digest", "missing-size", "invalid-digest",
                       "unsafe-path", "complete"):
            for model_id, capability, kind in (("migan", "inpaint.spot", "patch_edit"),
                                               ("swin2sr-x4", "upscale.4x", "upscale")):
                with self.subTest(defect=defect, model=model_id):
                    reason = None if defect == "complete" else defect
                    broken = tuple(
                        _repin(item, defect) if item.id == model_id else item
                        for item in SHIPPED)
                    shutil.rmtree(self.server.catalog.root, ignore_errors=True)
                    with patch("retouch_ai_worker.catalog.CATALOG", broken):
                        refused = self._run_kind_job(f"gate-{model_id}-{defect}",
                                                     kind=kind,
                                                     capability=capability)
                        listed = self.session.call("capability.list")
                    spot = next(item for item in listed["result"]["capabilities"]
                                if item["capabilityId"] == capability)
                    self.assertEqual(spot["state"], states[reason], listed)
                    # A named submission is always refused at the gate, before a
                    # job exists; what must agree with the report is its code.
                    self.assertIn("refused", refused, refused)
                    if spot["state"] == "blocked":
                        self.assertEqual(refused["refused"]["code"], UNSUPPORTED)
                        self.assertEqual(refused["refused"]["data"]["state"], "blocked")
                    else:
                        # Nothing installed stays a downloadable answer even when
                        # the pins are complete — never an integrity one.
                        self.assertEqual(refused["refused"]["code"], MODEL_MISSING)
                        self.assertEqual(refused["refused"]["data"]["model"], model_id)

    def test_a_kind_only_job_refuses_exactly_what_the_report_calls_blocked(self):
        # The complement of the gate test above: the same machine state reached
        # without a capability id has no gate to stand in front of it, so the
        # refusal must come from the loader with the integrity code. A blocked
        # capability that only ever failed at the gate would leave the documented
        # kind-only escape hatch loading bytes the report calls unverifiable.
        from retouch_ai_worker.catalog import CATALOG as SHIPPED

        for defect, code, reason in (
                ("missing-digest", CATALOG_INVALID, "missing-digest"),
                ("missing-size", CATALOG_INVALID, "missing-size"),
                ("invalid-digest", CATALOG_INVALID, "invalid-digest"),
                ("unsafe-path", CATALOG_INVALID, "unsafe-path")):
            with self.subTest(defect=defect):
                broken = tuple(_repin(item, defect) if item.id == "migan" else item
                               for item in SHIPPED)
                shutil.rmtree(self.server.catalog.root, ignore_errors=True)
                folder = self.server.catalog.root / "migan" / "1.0.0"
                folder.mkdir(parents=True)
                (folder / "migan_pipeline_v2.onnx").write_bytes(b"anything at all")
                (self.server.catalog.root / "migan" / "active.json").write_text(
                    json.dumps({"schema": "retouchstudio.model-active/1",
                                "modelId": "migan", "version": "1.0.0"}),
                    encoding="utf-8")
                with patch("retouch_ai_worker.catalog.CATALOG", broken):
                    error = self._run_kind_only_job(f"hatch-{defect}")
                self.assertEqual(error["code"], code)
                self.assertEqual(error["data"]["reason"], reason)

    def test_health_reports_an_unverifiable_catalog_entry_over_the_wire(self):
        # A null pin used to make `health()` answer ok:true for an installed model
        # it had checked against nothing. Over RPC that became a green launch probe
        # for bytes nobody had verified.
        from retouch_ai_worker.catalog import CATALOG as SHIPPED
        from retouch_ai_worker.catalog import ModelEntry, ModelFile

        broken = tuple(
            ModelEntry(id=item.id, name=item.name, task=item.task,
                       license_id=item.license_id, permitted_use=item.permitted_use,
                       source=item.source,
                       files=tuple(ModelFile(spec.path, None, spec.bytes)
                                   for spec in item.files))
            if item.id == "migan" else item for item in SHIPPED)
        target = self.server.catalog.root / "migan" / "migan_pipeline_v2.onnx"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"anything at all")
        with patch("retouch_ai_worker.catalog.CATALOG", broken):
            reply = self.session.call("health")["result"]
        self.assertFalse(reply["ok"])
        state = {item["model"]: item for item in reply["models"]}["migan"]
        self.assertTrue(state["installed"])
        self.assertFalse(state["ok"])
        self.assertEqual(state["problems"][0]["reason"], "missing-digest")
        # The report carries the same code the load path raises, so a host routing
        # the launch probe needs no second table of reasons.
        self.assertEqual(state["code"], CATALOG_INVALID)

    def test_health_never_hashes_and_still_costs_nothing_per_poll(self):
        # Cost invariant behind the cache: `health()` is called at launch and on
        # every capability poll, so it must stay a stat-only check. If it ever
        # starts hashing, this fails on the call count rather than on a slow CI.
        from retouch_ai_worker.catalog import _sha256

        calls = []
        with patch("retouch_ai_worker.catalog._sha256",
                   side_effect=lambda p: (calls.append(p), _sha256(p))[1]):
            for _ in range(20):
                self.session.call("health")
        self.assertEqual(calls, [], "health() hashed a model file")

    def test_capability_list_never_hashes(self):
        from retouch_ai_worker.catalog import _sha256

        calls = []
        with patch("retouch_ai_worker.catalog._sha256",
                   side_effect=lambda p: (calls.append(p), _sha256(p))[1]):
            for _ in range(20):
                self.session.call("capability.list")
        self.assertEqual(calls, [], "capability.list hashed a model file")

    def test_models_verify_reports_an_unverifiable_entry_without_raising(self):
        # The report shape the model manager consumes stays a report: a bad pin
        # becomes `unverifiable`, not an exception and not `ok`.
        from retouch_ai_worker.catalog import CATALOG as SHIPPED
        from retouch_ai_worker.catalog import ModelEntry, ModelFile

        broken = tuple(
            ModelEntry(id=item.id, name=item.name, task=item.task,
                       license_id=item.license_id, permitted_use=item.permitted_use,
                       source=item.source,
                       files=tuple(ModelFile(spec.path, "deadbeef", spec.bytes)
                                   for spec in item.files))
            if item.id == "migan" else item for item in SHIPPED)
        with patch("retouch_ai_worker.catalog.CATALOG", broken):
            reply = self.session.call("models.verify", {"model": "migan"})["result"]
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["checked"], 0)
        self.assertTrue(reply["unverifiable"])
        self.assertEqual(reply["failed"][0]["reason"], "invalid-digest")

    def test_a_plan_prices_only_bytes_this_worker_will_load(self):
        # Positive control for the three refusals below, and the only RPC-level
        # look `models.plan` had: a complete pin still yields the manifest the
        # consent sheet is hashed over, priced from the pinned lengths.
        from retouch_ai_worker.catalog import CATALOG as SHIPPED

        entry = next(item for item in SHIPPED if item.id == "migan")
        reply = self.session.call("models.plan", {"models": ["migan"]})
        self.assertNotIn("error", reply, reply)
        plan = reply["result"]
        self.assertEqual(plan["total_bytes"], sum(spec.bytes for spec in entry.files))
        self.assertEqual({item["path"] for item in plan["files"]},
                         {spec.path for spec in entry.files})
        self.assertEqual(plan["aggregate"]["files"], len(entry.files))
        self.assertEqual(plan["aggregate"]["sha256"], plan["manifest_hash"])
        for item in plan["files"]:
            # A plan the consent gate can be shown for has to name a source and a
            # digest for every byte it charges.
            self.assertTrue(item["url"], item)
            self.assertTrue(item["sha256"], item)
            self.assertIsNotNone(item["bytes"], item)

    def test_a_plan_refuses_every_pin_class_the_loader_refuses_over_rpc(self):
        # `test_downloads` pins admission in the downloader; this pins the *wire
        # answer* the model manager renders. The measured baseline was worse than
        # an error: an entry with a null pin charged `None` bytes into the consent
        # total, the transfer ran, and only the load refused — the user paid the
        # bandwidth to be told -32021. `spec.url` is deliberately kept intact by
        # `_repin` so a regression here prices a bad plan instead of accidentally
        # failing on a missing download source.
        from retouch_ai_worker.catalog import CATALOG as SHIPPED

        shipped = next(item for item in SHIPPED if item.id == "migan")
        for defect in ("missing-digest", "missing-size", "invalid-digest",
                       "unsafe-path"):
            with self.subTest(defect=defect):
                with patch("retouch_ai_worker.catalog.CATALOG",
                           (_repin(shipped, defect),)):
                    reply = self.session.call("models.plan", {"models": ["migan"]})
                self.assertNotIn("result", reply, reply)
                self.assertEqual(reply["error"]["code"], CATALOG_INVALID)
                self.assertEqual(reply["error"]["data"]["reason"], defect)
                self.assertNotIn("total_bytes", json.dumps(reply["error"]),
                                 "a refused plan still leaked a price")

    def test_a_plan_refuses_an_entry_that_names_no_files(self):
        # The fourth class, invisible to a per-file loop: an empty file list priced
        # a *free, empty* plan. It cleared the consent gate with 0 bytes, installed
        # nothing, and left every capability bound to a model that could never
        # load. `incomplete-entry` is the answer the UI needs, because no download
        # repairs a record that names nothing.
        from retouch_ai_worker.catalog import CATALOG as SHIPPED

        shipped = next(item for item in SHIPPED if item.id == "migan")
        empty = ModelEntry(id=shipped.id, name=shipped.name, task=shipped.task,
                           license_id=shipped.license_id,
                           permitted_use=shipped.permitted_use,
                           source=shipped.source, files=())
        with patch("retouch_ai_worker.catalog.CATALOG", (empty,)):
            reply = self.session.call("models.plan", {"models": ["migan"]})
        self.assertEqual(reply["error"]["code"], CATALOG_INVALID)
        self.assertEqual(reply["error"]["data"]["reason"], "incomplete-entry")
        self.assertNotIn("result", reply, reply)

    def test_a_licence_refusal_prices_no_plan_before_the_pin_is_examined(self):
        # Ordering is the product answer, not a detail: an entry that is both
        # unpermitted and mis-pinned must say -32010 ("we are not allowed to fetch
        # these weights"), never -32021 ("your install is corrupt"), because the
        # second invites a download the first forbids.
        shipped = cleared_use()
        unpermitted = ModelEntry(
            id="migan", name="MI-GAN", task="inpainting", license_id="MIT",
            permitted_use=uncleared_use(), source="local",
            files=(ModelFile("weights.bin", None, None),))
        with patch("retouch_ai_worker.catalog.CATALOG", (unpermitted,)):
            reply = self.session.call("models.plan", {"models": ["migan"]})
        self.assertEqual(reply["error"]["code"], LICENSE_BLOCKED)
        self.assertNotEqual(reply["error"]["code"], CATALOG_INVALID)
        self.assertEqual(reply["error"]["data"]["verdict"], "unknown")
        self.assertTrue(shipped.admitted, "the fixture's control record stopped "
                        "admitting, so this test no longer proves an ordering")

    def test_a_verification_failure_survives_the_job_record_verbatim(self):
        # The taxonomy is only useful if the code reaches the host unmodified.
        # A generic fault (-32603) or a swallowed exception here would look like a
        # worker crash to `WorkerClient.typedCode` and map to E_INTERNAL.
        self._install_migan(b"tampereD")
        pin = hashlib.sha256(b"trusted!").hexdigest()
        with patch("retouch_ai_worker.catalog.CATALOG", (self._migan_entry(pin),)):
            error = self._run_kind_only_job("record")
        self.assertEqual(error["code"], CHECKSUM_MISMATCH)
        for internal in (-32603, -32601, -32700):
            self.assertNotEqual(error["code"], internal)
        self.assertTrue({"model", "file", "reason"} <= set(error["data"]),
                        error["data"])

    def test_a_legacy_install_of_a_pinned_model_still_loads_over_rpc(self):
        # Fix constraint 2: adoption is app-side and hashes; the worker must keep
        # accepting the flat layout, or the gate strands an existing install.
        good = b"trusted!"
        pin = hashlib.sha256(good).hexdigest()
        self._install_migan(good, versioned=False)
        with patch("retouch_ai_worker.catalog.CATALOG", (self._migan_entry(pin),)):
            reply = self._run_kind_job("legacy")
        self.assertIsNone(reply.get("error"), reply)
        self.assertEqual(Path(reply["result"]["root"]).name, "migan")

    def test_a_legacy_install_is_refused_by_name_and_runs_by_kind(self):
        # The two submission shapes must answer differently for one and the same
        # install, which is what Docs/AI_PROTOCOL_V2.md §Capability reporting
        # freezes (`capabilityId` is optional, and the kind path "deliberately
        # does not refuse the blocked states that describe a claim"): naming a
        # capability the adapter cannot claim refuses before any work starts,
        # while naming only `kind` keeps an installed-but-unproven model running,
        # because running it is how the evidence for a claim gets recorded. Both
        # halves are pinned on the same machine state so the boundary cannot drift
        # quietly: closing the kind path would remove the documented escape hatch,
        # and opening the named path would make `supported` advisory again.
        catalog = self.use_shipping_catalog()
        flat = catalog.root / "swin2sr-x4"
        flat.mkdir(parents=True)
        for name, size in (("config.json", 772), ("preprocessor_config.json", 152),
                           ("pytorch_model.bin", 48_460_141)):
            with (flat / name).open("wb") as handle:
                handle.truncate(size)
        reported = {item["capabilityId"]: item for item in
                    self.session.call("capability.list")["result"]["capabilities"]}
        self.assertEqual(reported["upscale.4x"]["state"], "blocked")
        self.assertIn("without a version", reported["upscale.4x"]["reason"])

        refused = self.session.call("job.submit", {
            "kind": "upscale", "capabilityId": "upscale.4x", "params": {}})
        self.assertEqual(refused["error"]["code"], UNSUPPORTED)
        self.assertEqual(refused["error"]["data"]["state"], "blocked")
        self.assertEqual(self.manager.snapshot()["jobs"], [],
                         "a submission the gate refused left a job behind")

        self.manager.engine = ModelEngine(catalog)
        job_id = self.session.call("job.submit",
                                   {"kind": "upscale", "params": {}})["result"]["job_id"]
        deadline = time.time() + 5
        while time.time() < deadline:
            status = self.session.call("job.status", {"job_id": job_id})["result"]
            if status["status"] in ("succeeded", "failed", "cancelled"):
                break
            time.sleep(0.02)
        self.assertEqual(status["status"], "succeeded")

    def test_failed_job_reports_safe_error(self):
        job_id = self.session.call("job.submit",
                                   {"kind": "boom", "params": {}})["result"]["job_id"]
        deadline = time.time() + 5
        while time.time() < deadline:
            status = self.session.call("job.status", {"job_id": job_id})["result"]
            if status["status"] == "failed":
                break
            time.sleep(0.02)
        self.assertEqual(status["status"], "failed")
        result = self.session.call("job.result", {"job_id": job_id})["result"]
        self.assertEqual(result["error"]["message"], "bad input")

    def test_unknown_method(self):
        reply = self.session.call("nope")
        self.assertEqual(reply["error"]["code"], -32601)

    def test_malformed_frame_gets_parse_error(self):
        self.session.sock.sendall(b"{oops}\n")
        message = self.session.read_message()
        self.assertEqual(message["error"]["code"], -32700)


class TransportTests(unittest.TestCase):
    def test_path_outside_allowed_roots_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            allowed = Path(tmp) / "allowed"
            allowed.mkdir()
            secret = Path(tmp) / "secret.png"
            secret.write_bytes(b"x")
            with self.assertRaises(WorkerError) as caught:
                read_image({"path": str(secret)}, (allowed,), allowed)
            self.assertEqual(caught.exception.code, PATH_DENIED)

    def test_relative_path_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(WorkerError):
                read_image({"path": "relative.png"}, (Path(tmp),), Path(tmp))

    def test_data_url_roundtrip(self):
        import base64
        import io

        from PIL import Image

        buffer = io.BytesIO()
        Image.new("RGB", (8, 6), (10, 20, 30)).save(buffer, format="PNG")
        payload = "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode()
        with tempfile.TemporaryDirectory() as tmp:
            image = read_image({"data": payload}, (), Path(tmp))
            self.assertEqual(image.shape, (6, 8, 3))
            self.assertEqual(tuple(image[0, 0]), (10, 20, 30))


if __name__ == "__main__":
    unittest.main()
