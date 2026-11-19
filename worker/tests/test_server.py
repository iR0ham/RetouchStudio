import json
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

from retouch_ai_worker.catalog import Catalog
from retouch_ai_worker.capabilities import (PROVIDER, SUPPORTED, VOCABULARY,
                                            current_platform)
from retouch_ai_worker.protocol import (BUSY, CHECKSUM_MISMATCH, INVALID_PARAMS,
                                        MODEL_MISSING, PATH_DENIED, UNSUPPORTED,
                                        WorkerError, decode, encode)
from retouch_ai_worker.server import (JOB_LOCK_NAME, JobManager,
                                      acquire_folder_lock, WorkerServer)
from retouch_ai_worker.transport import read_image


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

    def test_hello(self):
        reply = self.session.call("hello")
        self.assertEqual(reply["result"]["protocol"], "2")
        self.assertEqual(reply["result"]["protocol_version"], 2)
        self.assertEqual(reply["result"]["helper_generation"],
                         self.server.helper_generation)
        self.assertEqual(reply["result"]["launch_nonce"], self.server.launch_nonce)
        self.assertEqual(reply["contractVersion"], "1")

    def test_models_list_marks_licenses(self):
        models = self.session.call("models.list")["result"]["models"]
        by_id = {model["id"]: model for model in models}
        self.assertTrue(by_id["flux2-klein-4b-q4"]["commercial_ok"])
        self.assertTrue(by_id["swin2sr-x4"]["commercial_ok"])
        self.assertEqual(by_id["swin2sr-x4"]["license"], "Apache-2.0")

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
        self.assertEqual(records["upscale.4x"]["state"], "requires_model")

    def test_capability_list_marks_the_recorded_upscale_run_supported(self):
        root = self.server.catalog.root
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

    def test_job_submit_reports_a_missing_model(self):
        reply = self.session.call("job.submit", {
            "kind": "upscale", "capabilityId": "upscale.4x", "params": {}})
        self.assertEqual(reply["error"]["code"], MODEL_MISSING)
        self.assertEqual(reply["error"]["data"]["model"], "swin2sr-x4")

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
        catalog = self.server.catalog
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
        # not installed here — and starts it as `requestedCapability`. Collapsing
        # the two would refuse shipped Quick Edit tools whose models carry no
        # recorded run, which is the A2 decision the owner has not made.
        gated = self.session.call("job.submit", {
            "kind": "patch_edit", "capabilityId": "generative.reimagine",
            "params": {}})
        self.assertEqual(gated["error"]["code"], MODEL_MISSING)

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
        version = self.server.catalog.root / "swin2sr-x4" / "1.0.0"
        version.mkdir(parents=True)
        for name, size in (("config.json", 772), ("preprocessor_config.json", 152),
                           ("pytorch_model.bin", 48)):
            with (version / name).open("wb") as handle:
                handle.truncate(size)
        (self.server.catalog.root / "swin2sr-x4" / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": "swin2sr-x4", "version": "1.0.0",
        }), encoding="utf-8")
        reported = {item["capabilityId"]: item
                    for item in self.session.call("capability.list")["result"]["capabilities"]}
        self.assertEqual(reported["upscale.4x"]["state"], "blocked")
        self.assertIn("size check", reported["upscale.4x"]["reason"])

        manager = JobManager(ModelEngine(self.server.catalog), root / "jobs",
                             (root / "inputs",))
        server = WorkerServer(root / "model.sock", manager, self.server.catalog,
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
        flat = self.server.catalog.root / "swin2sr-x4"
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

        self.manager.engine = ModelEngine(self.server.catalog)
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
