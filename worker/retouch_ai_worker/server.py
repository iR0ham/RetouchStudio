"""The worker server: JSON-RPC over a Unix domain socket.

Invariants this file exists to protect:

- one heavy job at a time (the machine has 16 GB, two models do not fit);
- the job thread never writes the input image;
- a job folder carries an exclusive flock while its job runs, which is how a
  sweep of the jobs root by another process knows to walk past it;
- no network code: model acquisition is a separate, user-initiated command run
  outside this server, and only the pure manifest builder is imported here;
- cancellation is acknowledged immediately and takes effect at the next
  denoising step, because a step cannot be interrupted from outside MLX.
"""
from __future__ import annotations

import fcntl
import logging
import os
import queue
import shutil
import socketserver
import threading
import time
import uuid
from pathlib import Path

from . import PROTOCOL_VERSION_STRING, __version__, provenance
from .protocol import CONTRACT_VERSION, PROTOCOL_VERSION
from .catalog import Catalog
from .capabilities import (BLOCKED, PROVIDER, capability_permission_refusal,
                           job_capability, record, report)
from .engine import Cancelled, Context, Engine
from .plan import manifest
from .protocol import (BUSY, INTERNAL_ERROR, INVALID_PARAMS, LICENSE_BLOCKED,
                       METHOD_NOT_FOUND, MODEL_MISSING, UNSUPPORTED, WorkerError,
                       decode, encode,
                       error_response, notification, parse_request,
                       result_response)
from .transport import BufferRegistry

LOG = logging.getLogger("retouch_ai_worker")

# A job's workdir holds pixels derived from the user's photo, and the host sweeps
# the ones a previous helper left behind: old and unlocked, the same rule the
# model store applies to its staging trees. `JOB_LOCK_NAME` is how a folder says
# "a job is writing here right now", including when that job belongs to a second
# worker sharing the root — a developer's `python -m retouch_ai_worker serve`,
# which defaults to the directory the app passes as `--jobs`. The kernel drops
# the flock when the holder dies, so a crash cannot leave a guard that outlives
# the job it protected.
JOB_LOCK_NAME = ".lock"


def acquire_folder_lock(folder: Path) -> int | None:
    """`LOCK_EX` on `<folder>/.lock`, or None when another process holds it.

    The caller keeps the returned descriptor for as long as the folder is
    live and closes it afterwards; the file itself is the folder's business.
    """
    try:
        handle = os.open(str(folder / JOB_LOCK_NAME), os.O_CREAT | os.O_RDWR, 0o600)
    except OSError:
        return None
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(handle)
        return None
    return handle


class JobManager:
    def __init__(self, engine: Engine, jobs_root: Path, allow_roots: tuple[Path, ...],
                 keep_jobs: int = 20) -> None:
        self.engine = engine
        self.jobs_root = Path(jobs_root)
        # Nothing of *this* worker's is in flight yet, but another process can
        # share the jobs root — a developer-launched worker defaults to the same
        # directory the app passes as `--jobs`. So the sweep takes its timestamp
        # before it looks and skips anything written at or after it: a crashed
        # run's orphan sidecars and half-written temps go, a live publication's
        # evidence stays. A sidecar that lands in the instant before the
        # timestamp can still be cleared, and the commit that was about to
        # verify it then fails and withdraws its artifact — a lost job, never an
        # unprovenanced one.
        swept_at = time.time()
        for folder in self.jobs_root.glob("*/"):
            provenance.reconcile(folder, not_newer_than=swept_at)
        self.allow_roots = allow_roots
        self.keep_jobs = keep_jobs
        self.buffers = BufferRegistry()
        self._jobs: dict[str, dict] = {}
        self._order: list[str] = []
        self._lock = threading.Lock()
        self._current: str | None = None
        self._subscribers: list[queue.Queue] = []

    # --- events -------------------------------------------------------
    def subscribe(self) -> queue.Queue:
        channel: queue.Queue = queue.Queue(maxsize=1024)
        with self._lock:
            self._subscribers.append(channel)
        return channel

    def unsubscribe(self, channel: queue.Queue) -> None:
        with self._lock:
            if channel in self._subscribers:
                self._subscribers.remove(channel)

    def _emit(self, method: str, params: dict) -> None:
        message = notification(method, params)
        with self._lock:
            subscribers = list(self._subscribers)
        for channel in subscribers:
            try:
                channel.put_nowait(message)
            except queue.Full:
                pass

    # --- lifecycle ----------------------------------------------------
    def submit(self, kind: str, params: dict, out_shm: str | None = None,
               capability_id: str | None = None,
               requested_capability: str | None = None) -> dict:
        with self._lock:
            if self._current is not None:
                raise WorkerError(BUSY, "another job is running",
                                  {"job": self._current})
            job_id = uuid.uuid4().hex[:12]
            self._current = job_id
            job = {
                "id": job_id,
                "kind": kind,
                "capability": capability_id,
                "requested_capability": requested_capability,
                "status": "queued",
                "created": time.time(),
                "started": None,
                "finished": None,
                "progress": {},
                "result": None,
                "error": None,
                "cancel": threading.Event(),
                "cancel_requested_at": None,
                "cancel_latency_ms": None,
            }
            self._jobs[job_id] = job
            self._order.append(job_id)
            self._trim()
        thread = threading.Thread(target=self._run, args=(job, params, out_shm),
                                  name=f"job-{job_id}", daemon=True)
        self._public(job)
        thread.start()
        return {"job_id": job_id}

    def _run(self, job: dict, params: dict, out_shm: str | None) -> None:
        workdir = self.jobs_root / job["id"]
        workdir.mkdir(parents=True, exist_ok=True)
        # Held for the whole render, so a sweep from the other direction — the
        # app clearing folders an earlier helper left — walks past this one even
        # if the job runs long enough that its last write falls outside the age
        # bound it checks.
        lock = acquire_folder_lock(workdir)
        ctx = Context(job_id=job["id"], workdir=workdir,
                      cancel=job["cancel"].is_set,
                      progress=lambda fields: self._progress(job, fields),
                      allow_roots=self.allow_roots,
                      buffers=self.buffers, out_shm=out_shm,
                      capability_id=job["capability"],
                      requested_capability=job["requested_capability"])
        job["status"] = "running"
        job["started"] = time.time()
        self._emit("job.started", {"job_id": job["id"], "kind": job["kind"]})
        try:
            result = self.engine.run(job["kind"], params, ctx)
        except Cancelled:
            job["status"] = "cancelled"
            job["finished"] = time.time()
            job["error"] = {"code": -32014, "message": "cancelled"}
        except WorkerError as exc:
            job["status"] = "failed"
            job["finished"] = time.time()
            job["error"] = exc.to_dict()
        except Exception as exc:  # noqa: BLE001 - the client gets a safe message
            LOG.exception("job %s crashed", job["id"])
            job["status"] = "failed"
            job["finished"] = time.time()
            job["error"] = {"code": INTERNAL_ERROR,
                            "message": f"{type(exc).__name__}: {exc}"}
        else:
            job["status"] = "succeeded"
            job["finished"] = time.time()
            job["result"] = result
        finally:
            with self._lock:
                self._current = None
            if job["cancel_requested_at"] is not None:
                # How long the adapter needed to reach a safe point after the
                # request; the acknowledgement itself is immediate.
                job["cancel_latency_ms"] = max(0, round(
                    (time.monotonic() - job["cancel_requested_at"]) * 1000, 1))
            self._emit("job.finished", self._public(job))
            # Released after the reply is out: the host reads the artifacts the
            # moment it sees this event, and the folder stays claimed until then.
            if lock is not None:
                os.close(lock)

    def _progress(self, job: dict, fields: dict) -> None:
        job["progress"] = fields
        self._emit("job.progress", {"job_id": job["id"], **fields})

    def cancel(self, job_id: str) -> dict:
        job = self._require(job_id)
        if job["status"] in ("succeeded", "failed", "cancelled"):
            return {"job_id": job_id, "status": job["status"], "cancel_requested": False}
        job["cancel"].set()
        if job["cancel_requested_at"] is None:
            job["cancel_requested_at"] = time.monotonic()
        if job["status"] == "running":
            job["status"] = "cancelling"
        self._emit("job.cancelling", {"job_id": job_id})
        return {"job_id": job_id, "status": job["status"], "cancel_requested": True}

    def status(self, job_id: str) -> dict:
        return self._public(self._require(job_id))

    def result(self, job_id: str) -> dict:
        job = self._require(job_id)
        if job["status"] not in ("succeeded", "failed", "cancelled"):
            raise WorkerError(INVALID_PARAMS, "job has not finished",
                              {"job_id": job_id, "status": job["status"]})
        result = {"job_id": job_id, "status": job["status"],
                  "result": job["result"], "error": job["error"],
                  "seconds": round((job["finished"] or time.time())
                                   - (job["started"] or job["created"]), 2)}
        if job["cancel_latency_ms"] is not None:
            result["cancelLatencyMs"] = job["cancel_latency_ms"]
        return result

    def snapshot(self) -> dict:
        with self._lock:
            return {"current": self._current,
                    "jobs": [self._public(self._jobs[j]) for j in self._order[-10:]]}

    def release_buffer(self, name: str) -> dict:
        self.buffers.release(name)
        return {"released": name}

    def drain(self) -> None:
        with self._lock:
            self._subscribers.clear()

    # --- helpers ------------------------------------------------------
    def _require(self, job_id: str) -> dict:
        if job_id not in self._jobs:
            raise WorkerError(INVALID_PARAMS, "unknown job", {"job_id": job_id})
        return self._jobs[job_id]

    def _trim(self) -> None:
        while len(self._order) > self.keep_jobs:
            oldest = self._order.pop(0)
            job = self._jobs.pop(oldest, None)
            if job and job["status"] in ("succeeded", "failed", "cancelled"):
                shutil.rmtree(self.jobs_root / oldest, ignore_errors=True)

    @staticmethod
    def _public(job: dict) -> dict:
        return {
            "job_id": job["id"],
            "kind": job["kind"],
            "status": job["status"],
            "progress": job["progress"],
            "seconds": round(((job["finished"] or time.time())
                              - (job["started"] or job["created"])), 2),
            "error": job["error"],
        }


class WorkerServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 8

    def __init__(self, socket_path: Path, manager: JobManager,
                 catalog: Catalog, allow_roots: tuple[Path, ...],
                 helper_generation: str | None = None,
                 launch_nonce: str | None = None) -> None:
        self.manager = manager
        self.catalog = catalog
        self.allow_roots = allow_roots
        self.helper_generation = helper_generation
        self.launch_nonce = launch_nonce
        self.accepting = threading.Event()
        self.accepting.set()
        self.socket_path = Path(socket_path)
        parent = self.socket_path.parent
        if not parent.exists():
            parent.mkdir(parents=True)
            os.chmod(parent, 0o700)
        super().__init__(str(self.socket_path), _Handler)
        # The socket is owner-only whatever the directory is (a QA run may put
        # it in /tmp, where the directory mode cannot be changed).
        os.chmod(self.socket_path, 0o600)

    def providers(self) -> list[dict]:
        """The execution providers this worker has really initialised.

        A fixed `CPU` was a claim the machine never made: the upscale path runs on
        MPS, and before any job no provider has been initialised at all.
        """
        devices, reason = self.manager.engine.execution_providers()
        provider = {"id": PROVIDER,
                    "state": "available" if devices else "unavailable",
                    "execution_providers": devices}
        if reason is not None:
            provider["reason"] = reason
        return [provider]

    def _require_capability(self, capability_id: str, kind: str) -> None:
        """Refuse a job the adapter does not truthfully provide.

        The host may name a capability; a missing model is E_MODEL_MISSING (the
        app opens the model manager), a refused permission is E_LICENCE_REFUSED
        (nothing opens, because nothing there settles it), and anything else is
        E_UNSUPPORTED. A request without a capability id keeps the pre-W5-3 job
        path unchanged: the model accessor then answers the licence first, so an
        unlabelled job still dies on the permission rather than on the weights.
        """
        spec = next((item for item in job_capability(kind)
                     if item.id == capability_id), None)
        if spec is None:
            raise WorkerError(UNSUPPORTED,
                              f"{capability_id} is not a {kind} capability",
                              {"capabilityId": capability_id, "kind": kind})
        refusal = capability_permission_refusal(capability_id, self.catalog)
        if refusal is not None:
            # The licence class, and not the generic one. A `blocked` capability
            # answered as `E_UNSUPPORTED` is what the host routes to Manage
            # Models, because a blocked capability normally waits for something
            # there — an adopt tap, an install, a recorded run. A permission is
            # none of those: the manager can only repeat the refusal, and the
            # sentence the host shows would offer a download that `manifest`
            # then refuses. Naming a capability has to answer with the class of
            # the thing that is actually missing.
            raise WorkerError(LICENSE_BLOCKED, refusal,
                              {"capabilityId": capability_id, "state": BLOCKED})
        item = record(capability_id, self.catalog)
        if item is None or item["state"] not in ("supported", "requires_model"):
            reason = (item or {}).get("reason") or "the adapter does not provide it"
            raise WorkerError(UNSUPPORTED, reason,
                              {"capabilityId": capability_id,
                               "state": (item or {}).get("state", "unsupported")})
        if item["state"] == "requires_model":
            raise WorkerError(MODEL_MISSING, item["reason"],
                              {"capabilityId": capability_id,
                               "model": item.get("modelId")})

    def _requested_capability(self, params: dict, kind: str) -> str | None:
        """The record-only capability name a host may attach to a job (A1).

        `capabilityId` is a gate: naming it means the worker must refuse the job
        unless it really provides that capability. `requestedCapability` is a
        label: the host says which product feature these bytes are evidence for
        so the provenance record can name it, and the worker only checks the
        name is one this kind can carry at all. It deliberately does not consult
        the model-state verdict — refusing a job for a name the adapter does
        render is the A2 decision the owner has not made.
        """
        requested = params.get("requestedCapability")
        if requested is None:
            return None
        requested = str(requested)
        if not any(item.id == requested for item in job_capability(kind)):
            raise WorkerError(INVALID_PARAMS,
                              f"{requested} is not a {kind} capability",
                              {"capabilityId": requested, "kind": kind})
        return requested

    # --- dispatch -----------------------------------------------------
    def dispatch(self, method: str, params: dict, connection) -> dict:
        if method == "hello":
            return {"contractVersion": CONTRACT_VERSION,
                    "protocol": PROTOCOL_VERSION_STRING,
                    "protocol_version": PROTOCOL_VERSION,
                    "worker": __version__,
                    "pid": os.getpid(),
                    "helper_generation": self.helper_generation,
                    "launch_nonce": self.launch_nonce,
                    "jobs": self.manager.snapshot(),
                    "models_root": str(self.catalog.root),
                    "allow_roots": [str(root) for root in self.allow_roots],
                    "providers": self.providers()}
        if method == "ping":
            return {"pong": True, "time": time.time()}
        if method == "models.list":
            return {"models": self.catalog.list()}
        if method == "health":
            return {"contractVersion": CONTRACT_VERSION,
                    "version": __version__, "protocol": PROTOCOL_VERSION_STRING,
                    "protocol_version": PROTOCOL_VERSION,
                    "pid": os.getpid(),
                    "helper_generation": self.helper_generation,
                    "launch_nonce": self.launch_nonce,
                    "providers": self.providers(),
                    **self.catalog.health()}
        if method == "provider.list":
            return {"contractVersion": CONTRACT_VERSION,
                    "providers": self.providers()}
        if method == "capability.list":
            return report(self.catalog)
        if method == "models.verify":
            return self.catalog.verify(str(params.get("model", "")))
        if method == "models.plan":
            return manifest(list(params.get("models") or []), self.catalog)
        if method == "job.submit":
            kind = params.get("kind")
            job_params = params.get("params") or {}
            if not isinstance(kind, str) or not isinstance(job_params, dict):
                raise WorkerError(INVALID_PARAMS, "kind and params are required")
            capability_id = params.get("capabilityId")
            if capability_id is not None:
                self._require_capability(str(capability_id), kind)
            return self.manager.submit(
                kind, job_params, params.get("out_shm"),
                str(capability_id) if capability_id else None,
                self._requested_capability(params, kind))
        if method == "job.status":
            return self.manager.status(str(params.get("job_id", "")))
        if method == "job.result":
            return self.manager.result(str(params.get("job_id", "")))
        if method == "job.cancel":
            return self.manager.cancel(str(params.get("job_id", "")))
        if method == "jobs.list":
            return self.manager.snapshot()
        if method == "buffer.release":
            return self.manager.release_buffer(str(params.get("name", "")))
        if method == "shutdown":
            self.accepting.clear()
            threading.Thread(target=self.shutdown, daemon=True).start()
            return {"stopping": True}
        raise WorkerError(METHOD_NOT_FOUND, f"unknown method {method!r}")


class _Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        server: WorkerServer = self.server  # type: ignore[assignment]
        channel = server.manager.subscribe()
        writer = _Writer(self.request)
        writer.start()
        self._writer = writer
        threading.Thread(target=self._pump, args=(channel, writer), daemon=True).start()
        try:
            for line in self.rfile:
                line = line.strip()
                if not line:
                    continue
                try:
                    request = parse_request(decode(line))
                except WorkerError as exc:
                    writer.send(error_response(None, exc))
                    continue
                try:
                    result = server.dispatch(request.method, request.params, self)
                    if not request.is_notification:
                        writer.send(result_response(request.id, result))
                except WorkerError as exc:
                    if not request.is_notification:
                        writer.send(error_response(request.id, exc))
                except Exception as exc:  # noqa: BLE001
                    LOG.exception("dispatch failed")
                    if not request.is_notification:
                        writer.send(error_response(request.id, WorkerError(
                            INTERNAL_ERROR, f"{type(exc).__name__}: {exc}")))
        finally:
            server.manager.unsubscribe(channel)
            channel.put(None)
            writer.stop()

    @staticmethod
    def _pump(channel: queue.Queue, writer: "_Writer") -> None:
        while True:
            message = channel.get()
            if message is None:
                return
            writer.send(message)


class _Writer(threading.Thread):
    """Serialises every frame for one connection; notifications and responses
    can race, and a half-written frame would desynchronise the client."""

    def __init__(self, sock) -> None:
        super().__init__(daemon=True)
        self.sock = sock
        self.queue: queue.Queue = queue.Queue()
        self.lock = threading.Lock()
        self.stopped = threading.Event()

    def send(self, message: dict) -> None:
        if not self.stopped.is_set():
            self.queue.put(message)

    def run(self) -> None:
        while True:
            message = self.queue.get()
            if message is None:
                return
            try:
                with self.lock:
                    self.sock.sendall(encode(message))
            except OSError:
                return

    def stop(self) -> None:
        self.stopped.set()
        self.queue.put(None)
