"""Phase 1 acceptance run: drives the worker only through its socket.

Checks, in order, against a real model on the real photo:

  protocol     hello / models.list / models.verify / models.plan refusal
  license      an uncleared model is refused before any file is touched
  throughput   N consecutive patch jobs, no crash, memory and swap per job
  lifecycle    a second submit while one job runs is refused (BUSY)
  cancel       acknowledged immediately, effective at the next denoise step
  integrity    every result is byte-identical outside the authorized region

Usage (from the Phase 0 root, with the worker already listening):

    .venv/bin/python worker/tools/acceptance.py \
        --socket "/tmp/rs-worker.sock" --jobs 10

The record is written as JSON so the report cites measurements, not memory.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import sys
import threading
import time
from pathlib import Path

import numpy as np
import psutil
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "worker"))

from retouch_ai_worker.morphology import dilate_binary, ellipse_kernel  # noqa: E402

DEFAULT_IMAGE = ROOT / "out" / "patchdemo" / "source-512.png"
DEFAULT_RECORD = ROOT / "out" / "phase1-acceptance.json"
PROMPT = ("Remove the wristwatch and continue the white knit sleeve and the skin "
          "underneath: natural daylight, photorealistic, seamless")


# --------------------------------------------------------------------------
class Client:
    """One connection; responses matched by id, notifications kept per job."""

    def __init__(self, path: str, timeout: float = 600.0) -> None:
        import socket

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
                if "id" in message and message["id"] is not None:
                    self.pending[message["id"]] = message
                else:
                    job_id = (message.get("params") or {}).get("job_id")
                    if job_id:
                        self.events.setdefault(job_id, []).append(message)
                self.cond.notify_all()
        with self.cond:
            self.closed = True
            self.cond.notify_all()

    def send(self, method: str, params: dict | None = None) -> int:
        with self.write_lock:
            self.next_id += 1
            request_id = self.next_id
            payload = {"jsonrpc": "2.0", "id": request_id, "method": method,
                       "params": params or {}}
            self.sock.sendall((json.dumps(payload) + "\n").encode())
        return request_id

    def wait(self, request_id: int, timeout: float | None = None) -> dict:
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

    def call(self, method: str, params: dict | None = None,
             timeout: float | None = None) -> dict:
        return self.wait(self.send(method, params), timeout)

    def wait_job(self, job_id: str, timeout: float = 600.0) -> dict:
        deadline = time.time() + timeout
        while True:
            with self.cond:
                for event in self.events.get(job_id, []):
                    if event["method"] == "job.finished":
                        return event["params"]
                if time.time() > deadline:
                    raise TimeoutError(f"job {job_id} did not finish")
                self.cond.wait(0.25)

    def job_result(self, job_id: str) -> dict:
        """The finished notification carries status only; the payload is fetched."""
        reply = self.call("job.result", {"job_id": job_id})
        return reply["result"]

    def steps(self, job_id: str) -> list[int]:
        with self.cond:
            return [int(e["params"].get("step", 0)) for e in self.events.get(job_id, [])
                    if e["method"] == "job.progress" and e["params"].get("stage") == "denoise"]

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


# --------------------------------------------------------------------------
def swap_gb() -> float:
    import subprocess

    raw = subprocess.check_output(["sysctl", "-n", "vm.swapusage"]).decode()
    used = raw.split("used =")[1].split("free")[0].strip()
    scale = {"K": 1e-6, "M": 1e-3, "G": 1.0}[used[-1]]
    return float(used[:-1]) * scale


class RssMonitor:
    def __init__(self, pid: int, interval: float = 0.1) -> None:
        self.proc = psutil.Process(pid)
        self.interval = interval
        self.peak = 0.0
        self.stop_flag = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self.stop_flag.is_set():
            try:
                self.peak = max(self.peak, self.proc.memory_info().rss / 1e9)
            except psutil.Error:
                return
            time.sleep(self.interval)

    def __enter__(self) -> "RssMonitor":
        self.start_swap = swap_gb()
        self.thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self.stop_flag.set()
        self.thread.join(timeout=2)


def data_url(array: np.ndarray) -> str:
    buffer = io.BytesIO()
    Image.fromarray(array).save(buffer, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode()


def dilate(mask: np.ndarray, radius: int) -> np.ndarray:
    return dilate_binary((mask > 127).astype(np.uint8), ellipse_kernel(radius)) * 255


# --------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default="/tmp/rs-worker.sock")
    parser.add_argument("--image", type=Path, default=DEFAULT_IMAGE)
    parser.add_argument("--record", type=Path, default=DEFAULT_RECORD)
    parser.add_argument("--jobs", type=int, default=10)
    parser.add_argument("--point", default="190,768", help="SAM click, x,y")
    parser.add_argument("--grow", type=int, default=10, help="mask dilation in px")
    parser.add_argument("--patch", type=int, default=512)
    parser.add_argument("--context", type=float, default=2.0)
    parser.add_argument("--steps", type=int, default=4)
    parser.add_argument("--prompt", default=PROMPT)
    parser.add_argument("--cancel-after", type=float, default=8.0)
    args = parser.parse_args()

    point = [float(v) for v in args.point.split(",")]
    record: dict = {"benchmark": "phase1-acceptance",
                    "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "socket": args.socket, "image": str(args.image),
                    "settings": {"point": point, "grow": args.grow,
                                 "patch": args.patch, "context": args.context,
                                 "steps": args.steps, "prompt": args.prompt,
                                 "jobs": args.jobs},
                    "swap_gb_at_start": round(swap_gb(), 3)}
    client = Client(args.socket)
    failures: list[str] = []

    try:
        hello = client.call("hello")
        if "result" not in hello:
            raise RuntimeError(f"hello failed: {hello}")
        worker_pid = hello["result"]["pid"]
        record["hello"] = {"protocol": hello["result"]["protocol"],
                           "worker": hello["result"]["worker"], "pid": worker_pid}
        print(f"hello: {record['hello']}")

        listing = client.call("models.list")
        models = listing["result"]["models"]
        record["models"] = [{k: m[k] for k in ("id", "license", "commercial_ok",
                                               "installed", "bytes")} for m in models]
        print("models:", [(m["id"], m["license"], m["installed"]) for m in models])

        refused = client.call("models.plan", {"models": ["lama-big"]})
        record["license_refusal"] = refused.get("error")
        refused_ok = refused.get("error", {}).get("code") == -32010
        print("uncleared model refusal:", record["license_refusal"])
        if not refused_ok:
            failures.append("uncleared model was not refused")

        plan = client.call("models.plan", {"models": ["flux2-klein-4b-q4"]})
        record["plan"] = {"manifest_hash": plan["result"]["manifest_hash"],
                          "total_bytes": plan["result"]["total_bytes"],
                          "files": len(plan["result"]["files"])}

        verify = client.call("models.verify", {"model": "flux2-klein-4b-q4"}, timeout=300)
        record["verify"] = verify["result"]
        print("verify:", {k: verify["result"][k] for k in ("model", "checked", "ok")})
        if not verify["result"]["ok"]:
            failures.append("flux checksums did not verify")

        mask_job = client.call("job.submit", {
            "kind": "mask",
            "params": {"image": {"path": str(args.image.resolve())},
                       "points": [point]}})
        mask_id = mask_job["result"]["job_id"]
        client.wait_job(mask_id)
        mask_result = client.job_result(mask_id)["result"]
        with Image.open(mask_result["mask"]) as handle:
            raw_mask = np.array(handle.convert("L"))
        grown = dilate(raw_mask, args.grow)
        record["mask"] = {"sam_fraction": round(mask_result["fraction"], 4),
                          "sam_score": round(mask_result["score"], 3),
                          "grown_fraction": round(float((grown > 127).mean()), 4),
                          "encode_s": mask_result["encode_s"],
                          "prompt_s": mask_result["prompt_s"]}
        print("mask:", record["mask"])
        mask_url = data_url(grown)

        runs = []
        for index in range(args.jobs):
            with RssMonitor(worker_pid) as monitor:
                started = time.perf_counter()
                submitted = client.call("job.submit", {
                    "kind": "patch_edit",
                    "params": {"image": {"path": str(args.image.resolve())},
                               "mask": {"data": mask_url},
                               "prompt": args.prompt, "patch": args.patch,
                               "context": args.context, "steps": args.steps,
                               "seed": 42 + index}})
                job_id = submitted["result"]["job_id"]
                finished = client.wait_job(job_id)
                detail = client.job_result(job_id)
                wall = time.perf_counter() - started
            run = {"index": index + 1, "job_id": job_id, "status": finished["status"],
                   "wall_s": round(wall, 2), "steps_seen": len(set(client.steps(job_id))),
                   "worker_peak_rss_gb": round(monitor.peak, 3),
                   "swap_delta_gb": round(swap_gb() - monitor.start_swap, 3),
                   "result": detail["result"], "error": finished["error"]}
            runs.append(run)
            print(f"job {run['index']}: {run['status']} {run['wall_s']} s "
                  f"rss {run['worker_peak_rss_gb']} GB "
                  f"swap {run['swap_delta_gb']:+} GB")
            if run["status"] != "succeeded":
                failures.append(f"job {run['index']} {run['status']}: {run['error']}")
                break
            result = run["result"] or {}
            if result.get("mode") != "patch":
                failures.append(f"job {run['index']} routed to {result.get('mode')}")
            if not result.get("outside_pixels_identical", False):
                failures.append(f"job {run['index']} changed pixels outside the mask")
        record["runs"] = runs

        # --- busy + cancel, one job each --------------------------------
        first = client.call("job.submit", {"kind": "patch_edit", "params": {
            "image": {"path": str(args.image.resolve())}, "mask": {"data": mask_url},
            "prompt": args.prompt, "patch": args.patch, "context": args.context,
            "steps": args.steps, "seed": 900}})
        busy_id = first["result"]["job_id"]
        second = client.call("job.submit", {"kind": "patch_edit", "params": {}})
        record["busy"] = second.get("error")
        busy_ok = second.get("error", {}).get("code") == -32012
        print("busy refusal:", record["busy"])
        if not busy_ok:
            failures.append("a second job was accepted while one was running")

        time.sleep(args.cancel_after)
        before = time.perf_counter()
        ack = client.call("job.cancel", {"job_id": busy_id})
        ack_s = time.perf_counter() - before
        finished = client.wait_job(busy_id, timeout=120)
        stop_s = time.perf_counter() - before
        record["cancel"] = {"ack_s": round(ack_s, 3),
                            "status_after_ack": ack["result"]["status"],
                            "stop_s": round(stop_s, 2),
                            "final_status": finished["status"],
                            "error": finished["error"]}
        print("cancel:", record["cancel"])
        if ack_s > 2.0:
            failures.append(f"cancel ack took {ack_s:.2f} s (> 2 s)")
        if finished["status"] != "cancelled":
            failures.append(f"cancelled job ended as {finished['status']}")

        # the worker must be usable again right after a cancel
        with RssMonitor(worker_pid) as monitor:
            started = time.perf_counter()
            recovery = client.call("job.submit", {"kind": "patch_edit", "params": {
                "image": {"path": str(args.image.resolve())}, "mask": {"data": mask_url},
                "prompt": args.prompt, "patch": args.patch, "context": args.context,
                "steps": args.steps, "seed": 77}})
            recovered = client.wait_job(recovery["result"]["job_id"])
            recovered_payload = client.job_result(recovery["result"]["job_id"])["result"] or {}
            wall = time.perf_counter() - started
        record["recovery"] = {"status": recovered["status"], "wall_s": round(wall, 2),
                              "outside_pixels_identical":
                                  recovered_payload.get("outside_pixels_identical"),
                              "swap_delta_gb": round(swap_gb() - monitor.start_swap, 3)}
        print("recovery:", record["recovery"])
        if recovered["status"] != "succeeded":
            failures.append("worker did not recover after a cancel")
        elif not recovered_payload.get("outside_pixels_identical", False):
            failures.append("recovery job changed pixels outside the mask")
    finally:
        client.close()

    succeeded = [r for r in record.get("runs", []) if r["status"] == "succeeded"]
    record["summary"] = {
        "jobs_succeeded": len(succeeded),
        "wall_s": [r["wall_s"] for r in succeeded],
        "median_wall_s": round(float(np.median([r["wall_s"] for r in succeeded])), 2)
                        if succeeded else None,
        "peak_worker_rss_gb": max((r["worker_peak_rss_gb"] for r in succeeded), default=None),
        "swap_deltas_gb": [r["swap_delta_gb"] for r in succeeded],
        "failures": failures,
        "ok": not failures and len(succeeded) == args.jobs,
    }
    args.record.parent.mkdir(parents=True, exist_ok=True)
    args.record.write_text(json.dumps(record, indent=2), "utf-8")
    print(json.dumps(record["summary"], indent=2))
    return 0 if record["summary"]["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
