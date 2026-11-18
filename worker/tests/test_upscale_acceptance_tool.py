"""The acceptance harness must be a runnable gate, not a promise (W5-5).

`tools/upscale_acceptance.py` is the tool the owner will point at a real
worker when the runtime approval in `Docs/W5_UPSCALER_ACCEPTANCE.md` is
granted. These tests run that exact file as a subprocess against a
deterministic fake engine over a real socket, so the harness's own protocol
handling, gate logic and refusal behaviour are regression-checked in CI
without any model, download or real inference.

Two runs, the same two the real approval would produce:

  refused  the worker reports `upscale.4x` not `supported`, so the harness
           must exit 2 claiming nothing;
  accepted the worker proves the capability from an evidence fixture and the
           harness judges its five gates (dimensions, provenance, cleanup,
           provider, cancelCleanup) to a pass.

The fake engine publishes through the real provenance module with the same
ordered publication the real upscale job uses, so the provenance gate means
what it says.
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from PIL import Image

from retouch_ai_worker.catalog import Catalog
from retouch_ai_worker.capabilities import PROVIDER, current_platform
from retouch_ai_worker.engine import WorkerError
from retouch_ai_worker.server import (JOB_LOCK_NAME, JobManager,
                                      WorkerServer)
from retouch_ai_worker import provenance

HARNESS = Path(__file__).resolve().parents[1] / "tools" / "upscale_acceptance.py"


class FakeUpscale:
    """The real job's shape, without a model: tile ticks, then publish."""

    def run(self, kind, params, ctx):
        if kind != "upscale":
            raise WorkerError(-32601, f"no such kind {kind}")
        import numpy as np

        for tick in range(30):
            ctx.check_cancel()
            ctx.emit("upscale", tile=tick, tiles=30)
            time.sleep(0.02)
        source = Image.open(params["image"]["path"]).convert("RGB")
        out = np.asarray(source.resize((source.width * 4, source.height * 4),
                                       Image.BILINEAR), dtype=np.uint8)
        ctx.check_cancel()
        result = ctx.workdir / "upscaled.png"
        staging = ctx.workdir / (result.name + ".tmp")
        Image.fromarray(out).save(staging, format="PNG")
        record = provenance.document(
            capability_id=ctx.capability_id or "upscale.4x",
            job_id=ctx.job_id, contract_version="1",
            model={"id": "swin2sr-x4", "version": None, "format": "pytorch",
                   "provider": "cpu", "files": []},
            adapter={"platform": "test", "version": "0.0.0"},
            parameters={"scale": 4}, seed=None,
            input=provenance.pixels(np.asarray(source)),
            output=provenance.artifact(staging),
            authorized_rect={"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0},
            outside_pixels_identical=None, elapsed_seconds=0.1,
            state="succeeded")
        sidecar = provenance.publish(staging, result, record)
        return {"output": str(result), "provenance": str(sidecar),
                "scale": 4, "device": "cpu", "provider": "cpu",
                "model": {"id": "swin2sr-x4"}, "tiles": 30, "seconds": 0.1,
                "image_size": [source.width, source.height],
                "output_size": [source.width * 4, source.height * 4]}

    def execution_providers(self):
        return ["cpu"], None


class HarnessToolTests(unittest.TestCase):
    """The harness file itself, driven end to end over a real socket."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.image = self.tmp / "input.png"
        Image.new("RGB", (24, 32), (10, 20, 30)).save(self.image)
        (self.tmp / "inputs").mkdir()
        catalog = Catalog(self.tmp / "models", allow_uncleared=False)
        self.jobs_root = self.tmp / "jobs"
        manager = JobManager(FakeUpscale(), self.jobs_root,
                             (self.tmp / "inputs",))
        self.server = WorkerServer(self.tmp / "worker.sock", manager, catalog,
                                   (self.tmp / "inputs",))
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": 0.05},
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _run(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(HARNESS),
             "--socket", str(self.tmp / "worker.sock"),
             "--image", str(self.image),
             "--jobs-root", str(self.jobs_root),
             "--cancel-after", "0.2",
             "--out", str(self.tmp / "record.json")],
            capture_output=True, text=True, timeout=180)

    def test_a_blocked_capability_is_refused_with_nothing_claimed(self):
        # No model installed: `capability.list` says requires_model, and the
        # harness must answer exit 2 with the recorded refusal instead of
        # submitting a job that cannot run.
        process = self._run()
        self.assertEqual(process.returncode, 2, process.stderr)
        record = json.loads((self.tmp / "record.json").read_text())
        self.assertEqual(record["verdict"], "not-runnable")
        self.assertIn("requires_model", record["reason"])

    def test_a_proven_capability_runs_to_a_judged_pass(self):
        # The same fixture the server tests use: exact-size install, active
        # version, and an evidence ledger naming this platform, so the gate
        # admits the capability for the reason it is really admitted.
        catalog = Catalog(self.tmp / "models", allow_uncleared=False)
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
            "modelId": entry.id, "version": "1.0.0"}), encoding="utf-8")
        ledger = self.tmp / "evidence.json"
        ledger.write_text(json.dumps({
            "schema": "retouchstudio.capability-evidence/1",
            "entries": [{"capabilityId": "upscale.4x",
                         "platform": current_platform(),
                         "provider": PROVIDER,
                         "modelId": entry.id, "modelVersion": "1.0.0",
                         "evidence": "the fixture this test installs"}]}),
            encoding="utf-8")

        with mock.patch.dict(os.environ,
                             {"RETOUCH_AI_CAPABILITY_EVIDENCE":
                              str(ledger)}):
            process = self._run()
        self.assertEqual(process.returncode, 0, process.stderr)
        record = json.loads((self.tmp / "record.json").read_text())
        self.assertEqual(record["verdict"], "pass")
        self.assertEqual({gate["gate"] for gate in record["gates"]},
                         {"dimensions", "provenance", "cleanup", "provider",
                          "cancelCleanup"})
        self.assertTrue(all(gate["verdict"] == "pass"
                            for gate in record["gates"]))
        cancelled = record["measurements"]["cancel"]
        self.assertEqual(cancelled["finishedStatus"], "cancelled")
        self.assertEqual(cancelled["errorCode"], -32014)
        # The success job's folder holds the published pair; the cancelled job's
        # folder holds no render of its own. Each also holds the `.lock` its job
        # claimed the workdir with, which is the folder's business and outlives
        # the job that wrote it; the harness's cleanup gates discount exactly that
        # name and no other.
        success = Path(record["measurements"]["jobFolder"])
        self.assertEqual(sorted(entry.name for entry in success.iterdir()),
                         sorted([JOB_LOCK_NAME, "upscaled.png",
                                 "upscaled.png.provenance.json"]))
        cancel_dir = self.jobs_root / cancelled["jobId"]
        self.assertEqual(sorted(entry.name for entry in cancel_dir.iterdir()),
                         [JOB_LOCK_NAME])


if __name__ == "__main__":
    unittest.main()
