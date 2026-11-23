"""W5-4 acceptance harness (§4.3): measures the macOS upscaler, invents nothing.

The frozen gates this tool can judge without a human are enforced; everything
else is recorded as a measurement, because the decision record fixes no
threshold for it. Nothing is downloaded, installed or inferred here that the
worker itself does not do: the harness speaks only to a listening worker over
its socket, on the same path the host uses.

Gates judged (frozen criteria, cited in the JSON record):

  dimensions   the output is exactly 4x the input                (§4.3)
  provenance   the adopted artifact carries a sidecar that names
               its own bytes, this capability and this model     (§3.6, §4.3)
  cleanup      a succeeded job's folder holds only the pair; a
               cancelled job's folder holds no artifact and no
               temp at all. The `.lock` a running job claims its
               workdir with belongs to the folder, not the render,
               and is not counted as a leftover.                (§4.3)
  provider     the device the result names is the device the
               worker's provider.list reports                    (§4.3)

Recorded, never judged (no frozen threshold exists for them):

  bit depth, ICC profile, alpha, EXIF orientation, wall and job seconds,
  tile count, peak RSS, swap, cancel latency, output SHA-256, PSNR
  (only when the caller supplies an owner-approved --reference).

Quality against the approved corpus is NOT run here: the corpus and its
tolerance are an owner decision recorded before the run (Docs/W5_UPSCALER_
ACCEPTANCE.md), and this tool invents neither.

Usage (worker already listening; no download, no install, no inference
beyond the one upscale job you are asking the worker to run):

    <runtime venv>/bin/python worker/tools/upscale_acceptance.py \
        --socket "$HOME/Library/Application Support/RetouchStudio/AI/worker.sock" \
        --image <24-bit or 16-bit input.png> \
        --jobs-root "$HOME/Library/Application Support/RetouchStudio/AI/jobs" \
        --cancel-after 2.0 \
        --out out/w54-acceptance.json

Exit codes: 0 every judged gate passed; 1 a judged gate failed;
2 the worker refuses to run the capability at all (state not `supported`),
so nothing was measured and nothing is claimed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import socket
import sys
import threading
import time
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parents[1]
sys.path.insert(0, str(ROOT / "worker"))

from retouch_ai_worker import provenance  # noqa: E402
from PIL import Image  # noqa: E402

CANCELLED = -32014
EXPECTED_CAPABILITY = "upscale.4x"
EXPECTED_MODEL = "swin2sr-x4"
# The file JobManager claims a workdir with while its job runs —
# retouch_ai_worker/server.py's JOB_LOCK_NAME. It belongs to the folder, not to
# the render, so the cleanup gates below allow for it and still refuse anything
# else. The name is restated rather than imported because pulling in the server
# module would pull in the engine, and the engine would pull in torch, for a
# tool that only ever speaks over a socket.
WORKDIR_LOCK = ".lock"


class Client:
    """One connection; responses matched by id, notifications kept per job.

    Small on purpose: tools/acceptance.py needs psutil, which the pinned
    worker runtime does not ship, and this harness must run there unchanged.
    """

    def __init__(self, path: str, timeout: float = 600.0) -> None:
        self.timeout = timeout
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.reader = self.sock.makefile("rb")
        self.write_lock = threading.Lock()
        self.cond = threading.Condition()
        self.pending: dict[int, dict] = {}
        self.events: dict[str, list[dict]] = {}
        self.next_id = 0
        self.closed = False
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self) -> None:
        for line in self.reader:
            if not line.strip():
                continue
            message = json.loads(line)
            with self.cond:
                if message.get("id") is not None:
                    self.pending[message["id"]] = message
                else:
                    job_id = (message.get("params") or {}).get("job_id")
                    if job_id:
                        self.events.setdefault(job_id, []).append(message)
                self.cond.notify_all()
        with self.cond:
            self.closed = True
            self.cond.notify_all()

    def call(self, method: str, params: dict | None = None,
             timeout: float | None = None) -> dict:
        with self.write_lock:
            self.next_id += 1
            request_id = self.next_id
            payload = {"jsonrpc": "2.0", "id": request_id, "method": method,
                       "params": params or {}}
            self.sock.sendall((json.dumps(payload) + "\n").encode())
        deadline = time.time() + (timeout or self.timeout)
        with self.cond:
            while request_id not in self.pending:
                if self.closed:
                    raise ConnectionError("worker closed the connection")
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise TimeoutError(f"no response to request {request_id}")
                self.cond.wait(min(remaining, 0.5))
            return self.pending.pop(request_id)

    def wait_finished(self, job_id: str, timeout: float = 1500.0) -> dict:
        deadline = time.time() + timeout
        while True:
            with self.cond:
                for event in self.events.get(job_id, []):
                    if event["method"] == "job.finished":
                        return event["params"]
                if time.time() > deadline:
                    raise TimeoutError(f"job {job_id} did not finish")
                self.cond.wait(0.25)

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


class RssMonitor:
    """Peak resident set of the worker, sampled while a job runs.

    Optional by dependency: psutil is a test-only convenience here, not a
    pinned worker requirement, so its absence is recorded rather than raised.
    """

    def __init__(self, pid: int, interval: float = 0.1) -> None:
        import psutil

        self.proc = psutil.Process(pid)
        self.interval = interval
        self.peak = 0.0
        self.stop_flag = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self.stop_flag.is_set():
            try:
                self.peak = max(self.peak, self.proc.memory_info().rss / 1e9)
            except Exception:
                return
            time.sleep(self.interval)

    def __enter__(self) -> "RssMonitor":
        self.thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self.stop_flag.set()
        self.thread.join(timeout=2)


def sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(block)
    return hasher.hexdigest()


def describe_image(path: Path) -> dict:
    with Image.open(path) as image:
        exif = image.getexif()
        return {"width": image.width, "height": image.height,
                "mode": image.mode,
                "bitDepth": 16 if "I;16" in image.mode or image.mode == "I"
                else 8,
                "channels": len(image.getbands()),
                "icc": bool(image.info.get("icc_profile")),
                "alpha": any(band in image.getbands()
                             for band in ("A", "transparency")),
                "exifOrientation": exif.get(274) if exif else None}


def gate(name: str, source: str, verdict: str, detail) -> dict:
    return {"gate": name, "frozen": source, "verdict": verdict,
            "detail": detail}


def psnr(reference: Image.Image, output: Image.Image) -> float | None:
    """Mean PSNR over RGB, or None when the pair is not comparable."""
    if reference.size != output.size:
        return None
    a = reference.convert("RGB")
    b = output.convert("RGB")
    import numpy as np

    diff = (np.asarray(a, dtype=np.float64)
            - np.asarray(b, dtype=np.float64)) ** 2
    mse = diff.mean()
    if mse == 0:
        return float("inf")
    return 10.0 * float(math.log10(255.0 ** 2 / mse))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--jobs-root", type=Path, default=None,
                        help="the worker's jobs root; enables folder-level "
                             "cleanup checks for the succeeded and cancelled "
                             "jobs")
    parser.add_argument("--tile", type=int, default=None)
    parser.add_argument("--cancel-after", type=float, default=2.0,
                        help="seconds into the cancel job before cancelling")
    parser.add_argument("--reference", type=Path, default=None,
                        help="an owner-approved upscale of --image, for a "
                             "recorded PSNR; no tolerance is applied here")
    parser.add_argument("--out", type=Path,
                        default=ROOT / "out" / "w54-acceptance.json")
    parser.add_argument("--job-timeout", type=float, default=1500.0)
    args = parser.parse_args()

    record: dict = {"harness": "w54-acceptance",
                    "started": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                             time.gmtime()),
                    "socket": args.socket, "image": str(args.image),
                    "gates": [], "measurements": {}}
    gates = record["gates"]
    measure = record["measurements"]
    measure["input"] = describe_image(args.image)

    client = Client(args.socket, timeout=args.job_timeout)
    try:
        hello = client.call("hello")["result"]
        record["protocol"] = {"protocol": hello.get("protocol"),
                              "protocol_version": hello.get("protocol_version")}
        health = client.call("health")["result"]
        record["workerPid"] = health.get("pid")

        capabilities = client.call("capability.list")["result"]
        reported = {item["capabilityId"]: item
                    for item in capabilities["capabilities"]}
        state = reported.get(EXPECTED_CAPABILITY, {})
        record["capability"] = state
        if state.get("state") != "supported":
            record["verdict"] = "not-runnable"
            record["reason"] = (f"{EXPECTED_CAPABILITY} is "
                                f"{state.get('state', 'absent')}: "
                                f"{state.get('reason', '')}")
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(record, indent=2),
                                encoding="utf-8")
            client.close()
            return 2

        models = {model["id"]: model
                  for model in client.call("models.list")["result"]["models"]}
        entry = models.get(EXPECTED_MODEL, {})
        reply = client.call("models.verify", {"model": EXPECTED_MODEL})
        verify = reply.get("result") or {"error": reply.get("error")}
        measure["model"] = {"license": entry.get("license"),
                            "permittedUse": entry.get("permitted_use"),
                            "verify": verify}

        # --- the acceptance job -------------------------------------------
        params: dict = {"image": {"path": str(args.image.resolve())}}
        if args.tile:
            params["tile"] = args.tile
        job_id = client.call("job.submit", {"kind": "upscale",
                                            "capabilityId":
                                                EXPECTED_CAPABILITY,
                                            "params": params}
                             )["result"]["job_id"]
        monitor = None
        try:
            monitor = RssMonitor(health["pid"])
        except ImportError:
            measure["peakRssGb"] = "not measured: psutil is not installed " \
                                   "in this runtime"
        started_wall = time.perf_counter()
        if monitor is not None:
            with monitor:
                finished = client.wait_finished(job_id, args.job_timeout)
        else:
            finished = client.wait_finished(job_id, args.job_timeout)
        wall_seconds = round(time.perf_counter() - started_wall, 2)

        status = client.call("job.status", {"job_id": job_id})["result"]
        if finished.get("status") != "succeeded":
            result = client.call("job.result", {"job_id": job_id})["result"]
            record["verdict"] = "not-runnable"
            record["reason"] = f"the acceptance job did not succeed: {result}"
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(record, indent=2),
                                encoding="utf-8")
            client.close()
            return 2

        result = client.call("job.result", {"job_id": job_id})["result"]
        # The manager's envelope wraps the engine's return: the host reads the
        # same nesting (WorkerClient unwraps the JSON-RPC result once, the
        # export reads `reply["result"]["output"]` inside it).
        payload = result.get("result") if isinstance(
            result.get("result"), dict) else {}
        artifact = Path(payload["output"])
        sidecar = Path(payload["provenance"])
        measure["output"] = describe_image(artifact)
        measure["output"]["sha256"] = sha256_file(artifact)
        measure["wallSeconds"] = wall_seconds
        measure["jobSeconds"] = payload.get("seconds")
        measure["device"] = payload.get("device")
        measure["tiles"] = {"tile": payload.get("tile"),
                            "overlap": payload.get("overlap"),
                            "count": payload.get("tiles"),
                            "meanMsPerTile": (
                                round(payload.get("seconds", 0) * 1000
                                      / max(payload.get("tiles", 1), 1), 1))
                            if payload.get("tiles") else None}
        measure["jobFolder"] = str(artifact.parent)
        if args.reference is not None:
            with Image.open(args.reference) as reference:
                with Image.open(artifact) as output:
                    measure["psnrVsReference"] = psnr(reference, output)

        # --- frozen gates -------------------------------------------------
        in_size, out_size = measure["input"], measure["output"]
        exact = (out_size["width"] == in_size["width"] * 4
                 and out_size["height"] == in_size["height"] * 4)
        gates.append(gate(
            "dimensions", "W5-0 §4.3: the output is exactly 4x the input",
            "pass" if exact else "fail",
            {"input": [in_size["width"], in_size["height"]],
             "output": [out_size["width"], out_size["height"]],
             "reportedScale": payload.get("scale")}))

        try:
            provenance_record = provenance.verify(artifact)
            honest = (provenance_record.get("capabilityId")
                      == EXPECTED_CAPABILITY
                      and (provenance_record.get("model") or {}).get("id")
                      == EXPECTED_MODEL
                      and provenance_record.get("state") == "succeeded"
                      and sidecar == provenance.sidecar_path(artifact)
                      and provenance_record["output"]["sha256"]
                      == measure["output"]["sha256"])
            gates.append(gate(
                "provenance",
                "W5-0 §3.6/§4.3: the artifact's sidecar names its own bytes, "
                "capability and model",
                "pass" if honest else "fail",
                {"sidecar": str(sidecar),
                 "capabilityId": provenance_record.get("capabilityId"),
                 "modelId": (provenance_record.get("model") or {}).get("id"),
                 "digestAgrees": honest}))
        except provenance.ProvenanceError as exc:
            gates.append(gate("provenance",
                              "W5-0 §3.6/§4.3: the artifact's sidecar names "
                              "its own bytes, capability and model",
                              "fail", str(exc)))

        job_folder = artifact.parent if args.jobs_root else None
        if job_folder is not None:
            # The frozen criterion is about what the *render* leaves behind, so
            # the folder's own claim file is not counted as a leftover; every
            # other name still has to be one of the pair.
            entries = sorted(entry.name for entry in job_folder.iterdir()
                             if entry.name != WORKDIR_LOCK)
            clean = entries == ["upscaled.png",
                                "upscaled.png.provenance.json"]
            gates.append(gate(
                "cleanup",
                "W5-0 §4.3: a succeeded job leaves only the published pair",
                "pass" if clean else "fail", {"left": entries}))

        provider = client.call("provider.list")["result"]["providers"][0]
        named = payload.get("device")
        agrees = (provider.get("state") == "available"
                  and bool(named) and named in provider.get(
                      "execution_providers", []))
        gates.append(gate(
            "provider",
            "W5-0 §4.3: the provider named by the result is the one the "
            "worker reports",
            "pass" if agrees else "fail",
            {"resultNamed": named,
             "providerList": provider.get("execution_providers"),
             "providerState": provider.get("state")}))
        measure["providerList"] = provider.get("execution_providers")

        # --- the cancel job -----------------------------------------------
        cancel_job = client.call("job.submit", {"kind": "upscale",
                                                "capabilityId":
                                                    EXPECTED_CAPABILITY,
                                                "params": params}
                                 )["result"]["job_id"]
        time.sleep(args.cancel_after)
        cancel_started = time.perf_counter()
        client.call("job.cancel", {"job_id": cancel_job})
        cancelled = client.wait_finished(cancel_job, args.job_timeout)
        cancel_latency_ms = round(
            (time.perf_counter() - cancel_started) * 1000, 1)
        measure["cancel"] = {"jobId": cancel_job,
                             "finishedStatus": cancelled.get("status"),
                             "latencyMs": cancel_latency_ms}
        if cancelled.get("status") == "cancelled":
            cresult = client.call("job.result",
                                  {"job_id": cancel_job})["result"]
            measure["cancel"]["errorCode"] = (cresult.get("error") or {}).get(
                "code")
            if args.jobs_root is not None:
                folder = args.jobs_root / cancel_job
                # As above: the workdir's own claim is not a leftover of the
                # cancelled render, so it is not counted and nothing else is
                # allowed.
                leftovers = sorted(entry.name for entry in folder.iterdir()
                                   if entry.name != WORKDIR_LOCK) \
                    if folder.is_dir() else []
                clean = leftovers == []
                gates.append(gate(
                    "cancelCleanup",
                    "W5-0 §4.3: cancellation leaves no artifact and no temp",
                    "pass" if clean else "fail",
                    {"left": leftovers,
                     "errorCode": measure["cancel"].get("errorCode")}))
        else:
            # The job outran the cancel request; record that, claim nothing.
            gates.append(gate(
                "cancelCleanup",
                "W5-0 §4.3: cancellation leaves no artifact and no temp",
                "skipped",
                f"the job finished as {cancelled.get('status')} before the "
                f"cancel landed; raise --cancel-after to exercise it"))

        judged = [g for g in gates if g["verdict"] != "skipped"]
        record["verdict"] = ("pass" if all(g["verdict"] == "pass"
                                           for g in judged) else "fail")
    finally:
        client.close()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(record, indent=2), encoding="utf-8")
    print(json.dumps({gate["gate"]: gate["verdict"] for gate in gates},
                     indent=2))
    print(f"record: {args.out}")
    return 0 if record["verdict"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
