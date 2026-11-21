"""Wire format for the Retouch Studio AI worker.

Newline-delimited JSON-RPC 2.0 over a Unix domain socket. One JSON object per
line, UTF-8, no embedded newlines (json.dumps never emits raw newlines). The
transport is deliberately boring: a line reader cannot desynchronise on a frame
boundary, and a human can debug a session with `nc -U`.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

MAX_FRAME_BYTES = 1 * 1024 * 1024
PROTOCOL_VERSION = 2
CONTRACT_VERSION = "1"

# JSON-RPC 2.0 reserved codes plus the worker's own range.
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603
LICENSE_BLOCKED = -32010
MODEL_MISSING = -32011
BUSY = -32012
BUDGET_EXCEEDED = -32013
CANCELLED = -32014
PATH_DENIED = -32015
UNKNOWN_MODEL = -32016
CONSENT_REQUIRED = -32017
DOWNLOAD_FAILED = -32018
CHECKSUM_MISMATCH = -32019
# Additive in contract 1: the catalog itself is not usable. A model file whose
# recorded size or SHA-256 is missing, or a digest that is not 64 hex
# characters, is a defect no download can repair, so it must not be reported as
# "damaged weights" (-32019) nor as "not installed" (-32011). Both hosts map
# this code to E_MODEL_UNVERIFIED, which is the honest label: the bytes cannot be
# verified against anything.
CATALOG_INVALID = -32021
# Additive in contract 1: a capability this adapter or platform does not
# provide. The frozen W5-0 vocabulary has no numeric code of its own; the host
# maps this code to E_UNSUPPORTED.
UNSUPPORTED = -32020


class WorkerError(Exception):
    """An error that is safe to send back to the app verbatim."""

    def __init__(self, code: int, message: str, data: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data or {}

    def to_dict(self) -> dict[str, Any]:
        error = {"code": self.code, "message": self.message}
        if self.data:
            error["data"] = self.data
        return error


@dataclass
class Request:
    method: str
    params: dict[str, Any] = field(default_factory=dict)
    id: int | str | None = None
    is_notification: bool = False
    contract_version: str | None = None


def encode(message: dict[str, Any]) -> bytes:
    return (json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def decode(line: bytes) -> dict[str, Any]:
    if len(line) > MAX_FRAME_BYTES:
        raise WorkerError(INVALID_REQUEST, "frame too large")
    try:
        message = json.loads(line)
    except json.JSONDecodeError as exc:
        raise WorkerError(PARSE_ERROR, f"invalid JSON: {exc.msg}") from exc
    if not isinstance(message, dict):
        raise WorkerError(INVALID_REQUEST, "frame must be a JSON object")
    return message


def parse_request(message: dict[str, Any]) -> Request:
    if message.get("jsonrpc") != "2.0":
        raise WorkerError(INVALID_REQUEST, 'jsonrpc must be "2.0"')
    method = message.get("method")
    if not isinstance(method, str) or not method:
        raise WorkerError(INVALID_REQUEST, "method must be a non-empty string")
    params = message.get("params", {})
    if params is None:
        params = {}
    if not isinstance(params, dict):
        raise WorkerError(INVALID_PARAMS, "params must be an object")
    contract_version = message.get("contractVersion")
    if contract_version is not None and contract_version != CONTRACT_VERSION:
        raise WorkerError(INVALID_REQUEST, "unsupported contract version",
                          {"contractVersion": contract_version})
    has_id = "id" in message
    return Request(
        method=method,
        params=params,
        id=message.get("id"),
        is_notification=not has_id,
        contract_version=contract_version,
    )


def result_response(request_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "contractVersion": CONTRACT_VERSION,
            "result": result}


def error_response(request_id: Any, error: WorkerError) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "contractVersion": CONTRACT_VERSION,
            "error": error.to_dict()}


def notification(method: str, params: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "contractVersion": CONTRACT_VERSION,
            "method": method, "params": params}
