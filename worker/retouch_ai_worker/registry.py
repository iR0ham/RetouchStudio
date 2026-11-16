"""Protocol-v2 readiness record written by the helper itself.

The host creates a `preparing` record, starts the helper with the generation,
launch nonce and registry path, and waits for the same launch to publish
`ready`. This module owns only that child side of the contract: it never
invents a generation, never overwrites another launch, and writes a private
file atomically under the host's permanent registry lock.

The JSON shape is frozen by `Sources/RetouchStudio/Core/HelperRegistry.swift`.
Both sides must be changed together.
"""
from __future__ import annotations

import ctypes
import errno
import fcntl
import json
import os
import time
import uuid
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 2
_FILE_NAME = "helper-registry.json"
_LOCK_NAME = "helper-registry.lock"

_PROC_PIDTBSDINFO = 3
_MAXPATHLEN = 4096


class _ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def process_identity(pid: int | None = None) -> dict[str, Any] | None:
    """The same identity the host records: pid, kernel start time, executable."""
    pid = os.getpid() if pid is None else pid
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        info = _ProcBsdInfo()
        copied = libc.proc_pidinfo(
            ctypes.c_int(pid),
            ctypes.c_int(_PROC_PIDTBSDINFO),
            ctypes.c_uint64(0),
            ctypes.byref(info),
            ctypes.c_int(ctypes.sizeof(info)),
        )
        if copied != ctypes.sizeof(info):
            return None
        buffer = ctypes.create_string_buffer(_MAXPATHLEN)
        length = libc.proc_pidpath(ctypes.c_int(pid), buffer, _MAXPATHLEN)
        if length <= 0:
            return None
        executable = os.path.realpath(buffer.value.decode("utf-8", "surrogateescape"))
        return {
            "pid": pid,
            "start_seconds": int(info.pbi_start_tvsec),
            "start_microseconds": int(info.pbi_start_tvusec),
            "executable": executable,
        }
    except (AttributeError, OSError, ValueError):
        return None


class RegistryWriter:
    """Publishes starting/ready/failed for exactly one launch attempt."""

    def __init__(self, path: Path, generation: str, launch_nonce: str,
                 socket: str) -> None:
        self.path = Path(path)
        self.root = self.path.parent
        self.generation = generation
        self.launch_nonce = launch_nonce
        self.socket = socket

    def _locked(self, mutate) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        lock_path = self.root / _LOCK_NAME
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW,
                     0o600)
        try:
            info = os.fstat(fd)
            if not (info.st_mode & 0o170000) == 0o100000 or info.st_mode & 0o077:
                raise RuntimeError("the helper registry lock is not private")
            deadline = time.monotonic() + 5
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("the helper registry is busy")
                    time.sleep(0.05)
            record = self._read()
            updated = mutate(record)
            if updated is not None:
                self._write(updated)
        finally:
            os.close(fd)

    def _read(self) -> dict[str, Any] | None:
        try:
            with self.path.open("rb") as handle:
                raw = handle.read(1 << 20)
            if not raw:
                return None
            record = json.loads(raw)
            return record if isinstance(record, dict) else None
        except FileNotFoundError:
            return None
        except (OSError, ValueError):
            return None

    def _write(self, record: dict[str, Any]) -> None:
        payload = json.dumps(record, ensure_ascii=False, separators=(",", ":"),
                             sort_keys=True).encode("utf-8")
        temp = self.root / f".{_FILE_NAME}.{uuid.uuid4()}.tmp"
        fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW
                     | os.O_CLOEXEC, 0o600)
        try:
            offset = 0
            while offset < len(payload):
                offset += os.write(fd, payload[offset:])
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temp, self.path)
        directory = os.open(self.root, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

    def _base(self, previous: dict[str, Any] | None, state: str,
              helper: dict[str, Any] | None, error: str | None = None) -> dict[str, Any]:
        now = time.time()
        if previous is not None:
            if previous.get("generation") != self.generation \
                    or previous.get("launch_nonce") != self.launch_nonce:
                raise RuntimeError("the registry names a different launch")
            revision = int(previous.get("revision") or 0) + 1
            created = float(previous.get("created_at") or now)
            parent = previous.get("parent")
            clients = previous.get("clients") or []
        else:
            revision = 1
            created = now
            parent = None
            clients = []
        return {
            "schema": SCHEMA_VERSION,
            "protocol_version": 2,
            "generation": self.generation,
            "launch_nonce": self.launch_nonce,
            "revision": revision,
            "state": state,
            "parent": parent,
            "helper": helper,
            "socket": self.socket,
            "created_at": created,
            "updated_at": now,
            "shutdown": None,
            "clients": clients,
            "last_error": error,
        }

    def starting(self) -> None:
        identity = process_identity()
        if identity is None:
            raise RuntimeError("could not identify this process")

        def mutate(previous):
            return self._base(previous, "starting", identity)

        self._locked(mutate)

    def ready(self) -> None:
        identity = process_identity()
        if identity is None:
            raise RuntimeError("could not identify this process")

        def mutate(previous):
            if previous is not None:
                state = previous.get("state")
                if state not in ("preparing", "starting"):
                    raise RuntimeError("the registry launch is no longer preparing")
            return self._base(previous, "ready", identity)

        self._locked(mutate)

    def failed(self, reason: str) -> None:
        def mutate(previous):
            base = self._base(previous, "failed", None, reason)
            base["parent"] = None
            return base

        try:
            self._locked(mutate)
        except Exception:  # noqa: BLE001 - best effort while already failing
            pass
