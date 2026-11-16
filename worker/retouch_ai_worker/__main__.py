"""Command line entry point.

`serve` runs the worker. Everything else is a local tool: inspect the catalog,
verify checksums, or drive a session from a terminal for QA. The only command
that touches the network is `models download`, and it requires an explicit
`--yes` after printing the exact manifest the user is approving.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import socket
import sys
import time
import uuid
from pathlib import Path

from . import __version__
from .catalog import MODEL_ROOT, Catalog
from .protocol import (PROTOCOL_VERSION, WorkerError, decode, encode,
                       error_response, result_response)
from .registry import RegistryWriter

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "RetouchStudio" / "AI"
DEFAULT_SOCKET = APP_SUPPORT / "worker.sock"
DEFAULT_JOBS = APP_SUPPORT / "jobs"


def _catalog(args) -> Catalog:
    return Catalog(Path(args.models) if args.models else MODEL_ROOT)


def _serve(args) -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    requested = args.protocol_version
    if requested is not None and requested != PROTOCOL_VERSION:
        print(f"unsupported protocol version {requested}", file=sys.stderr)
        return 2
    generation = args.helper_generation
    nonce = args.launch_nonce
    if (generation is None) != (nonce is None):
        print("--helper-generation and --launch-nonce must be passed together",
              file=sys.stderr)
        return 2
    for value in (generation, nonce):
        if value is not None:
            try:
                uuid.UUID(value)
            except ValueError:
                print("the helper identity arguments must be UUIDs", file=sys.stderr)
                return 2
    if generation is not None and not args.registry:
        print("--registry is required with --helper-generation", file=sys.stderr)
        return 2
    if args.usage_fd is not None:
        try:
            os.fstat(args.usage_fd)
        except OSError:
            print("the inherited usage descriptor is not open", file=sys.stderr)
            return 2

    from .engine import Engine
    from .server import JobManager, WorkerServer

    registry = (RegistryWriter(Path(args.registry), generation, nonce, args.socket)
                if generation is not None else None)
    try:
        if registry is not None:
            registry.starting()
        catalog = _catalog(args)
        allow_roots = tuple(Path(root).expanduser().resolve() for root in args.allow_root)
        engine = Engine(catalog, allow_roots)
        manager = JobManager(engine, Path(args.jobs), allow_roots,
                             keep_jobs=args.keep_jobs)
        server = WorkerServer(Path(args.socket), manager, catalog, allow_roots,
                              helper_generation=generation, launch_nonce=nonce)
        if registry is not None:
            registry.ready()
        print(json.dumps({"listening": str(server.socket_path), "pid": os.getpid(),
                          "protocol_version": PROTOCOL_VERSION}), flush=True)
    except Exception as exc:  # noqa: BLE001 - startup failure must be visible
        if registry is not None:
            registry.failed(f"{type(exc).__name__}: {exc}")
        print(f"the worker could not start: {exc}", file=sys.stderr)
        return 1
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        Path(args.socket).unlink(missing_ok=True)
    return 0


def _models(args) -> int:
    catalog = _catalog(args)
    if args.action == "list":
        print(json.dumps(catalog.list(), indent=2))
        return 0
    if args.action == "verify":
        result = catalog.verify(args.model)
        print(json.dumps(result, indent=2))
        return 0 if result["ok"] else 1
    if args.action == "plan":
        from .plan import manifest
        print(json.dumps(manifest(args.model, catalog), indent=2))
        return 0
    if args.action == "download":
        from .downloads import ConsentStore, Downloader, consent_hash_matches
        consent = ConsentStore(APP_SUPPORT / "download-consent.json")
        downloader = Downloader(catalog.root, catalog, consent)
        plan = downloader.plan(args.model)
        print(json.dumps({"plan": plan}, indent=2))
        if not consent_hash_matches(plan, args.consent_hash):
            print("the manifest changed since it was shown; nothing downloaded",
                  file=sys.stderr)
            return 3
        if not args.yes:
            print("\nNothing downloaded. Re-run with --yes to approve exactly this "
                  "manifest, or grant consent in the app.", file=sys.stderr)
            return 2
        consent.grant(plan, note="approved from command line")

        def progress(fields: dict) -> None:
            print(json.dumps({"download": fields}), file=sys.stderr)

        print(json.dumps(downloader.fetch(args.model, progress=progress), indent=2))
        return 0
    return 2


def _call(args) -> int:
    payload = {"jsonrpc": "2.0", "id": 1, "method": args.method,
               "params": json.loads(args.params) if args.params else {}}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(args.socket)
        client.sendall(encode(payload))
        buffer = b""
        while b"\n" not in buffer:
            block = client.recv(65536)
            if not block:
                break
            buffer += block
    line = buffer.split(b"\n", 1)[0]
    print(json.dumps(decode(line), indent=2))
    return 0


def _selftest(args) -> int:
    catalog = _catalog(args)
    checks = []
    try:
        checks.append({"check": "catalog", "ok": True, "models": len(catalog.list())})
    except Exception as exc:  # noqa: BLE001
        checks.append({"check": "catalog", "ok": False, "error": str(exc)})
    for entry in catalog.list():
        if entry["installed"]:
            report = catalog.verify(entry["id"])
            checks.append({"check": f"verify:{entry['id']}", "ok": report["ok"],
                           "failed": report["failed"]})
    ok = all(check["ok"] for check in checks)
    print(json.dumps({"selftest": ok, "version": __version__, "checks": checks},
                     indent=2))
    return 0 if ok else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="retouch_ai_worker")
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", required=True)

    serve = sub.add_parser("serve", help="run the worker server")
    serve.add_argument("--socket", default=str(DEFAULT_SOCKET))
    serve.add_argument("--jobs", default=str(DEFAULT_JOBS))
    serve.add_argument("--models", default=None)
    serve.add_argument("--allow-root", action="append", default=[])
    serve.add_argument("--keep-jobs", type=int, default=20)
    serve.add_argument("--protocol-version", type=int, default=None)
    serve.add_argument("--helper-generation", default=None)
    serve.add_argument("--launch-nonce", default=None)
    serve.add_argument("--registry", default=None)
    serve.add_argument("--usage-fd", type=int, default=None)
    serve.set_defaults(func=_serve)

    models = sub.add_parser("models", help="inspect and install models")
    models.add_argument("action", choices=["list", "verify", "plan", "download"])
    models.add_argument("model", nargs="*")
    models.add_argument("--models", default=None)
    models.add_argument("--yes", action="store_true")
    models.add_argument("--consent-hash", default=None,
                        help="manifest hash the owner approved; refuse if it changed")
    models.set_defaults(func=_models)

    call = sub.add_parser("call", help="send one JSON-RPC request (QA)")
    call.add_argument("method")
    call.add_argument("params", nargs="?")
    call.add_argument("--socket", default=str(DEFAULT_SOCKET))
    call.set_defaults(func=_call)

    test = sub.add_parser("selftest", help="verify installed models")
    test.add_argument("--models", default=None)
    test.set_defaults(func=_selftest)

    args = parser.parse_args(argv)
    if args.command == "models":
        if args.action in ("plan", "download"):
            if not args.model:
                parser.error(f"models {args.action} needs at least one model id")
            args.model = list(args.model)
        elif args.action == "verify":
            if len(args.model) != 1:
                parser.error("models verify takes exactly one model id")
            args.model = args.model[0]
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
