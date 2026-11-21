"""Prove the shipping runtime closes over what the worker imports.

Two gaps are checked here, without wheels or network:

  imports   every third-party module the shipped package imports has a
            distribution pinned in `requirements.lock`. This is the failure
            mode that bit the engine once: code imported `cv2`, the pin was
            absent, and the break surfaced as an ImportError on the owner's
            machine instead of in CI. An import guarded by `except
            ImportError` or `except ModuleNotFoundError` is exempt — it is a
            deliberate refusal path, not a dependency — but it is still
            reported so the exemption is visible. A broader handler is not
            exempt: `except Exception:` and bare `except:` also catch errors
            raised by the imported module itself, so they prove nothing about
            whether the dependency is optional, and a hard import behind one
            is still required to be pinned;
  lock      every pin is exact (`name==version`), carries at least one
            SHA-256, appears once, and the test lock does not name a package
            or version the runtime lock does not.

`--report <json>` additionally reads a `pip install --dry-run --report`
document and proves the resolver picked exactly the locked set — no
transitive it resolved on its own, no direct URL, and the same versions.

What it does not prove: that a wheel exists for every platform (the resolver
run itself proves that, on the runner's own platform), that the packages
import at runtime (lazy imports need a real environment), or that a dynamic
capability probe names a shipped package — `capabilities.py` asks
`find_spec("sam2")` to decide whether a capability is available, and that
answer is allowed to be "no".

An import this walk cannot read is not silently dropped. A functional import
whose module name is not a string literal reachable statically —
`__import__(module_variable)`, `importlib.import_module(computed)` — is a
violation naming its file and line, because a gate that reported nothing for an
import it could not see would be an escape hatch. `audit(..., allow_dynamic=True)`
opts a specific call site out when an unreadable import is genuinely expected;
nothing in the shipped package needs it today.

The precise residual limit, stated so nobody has to re-derive it: recognition
needs to know that a call imports something. A literal name inside a recognised
importer is audited; a call to a recognised importer with a non-literal name is
reported as unreadable; but code that hides the importer itself behind a
computation — `getattr(importlib, "import_module")`, `globals()["__import__"]`,
an alias assigned from something other than a `from importlib import ...`
statement — presents no function name to classify, so it is invisible to this
walk exactly as it was before. Closing that would mean evaluating arbitrary
Python during the audit; the honest mitigation is that such code is loud in
review, and `import_smoke.run` still fails if the module it imports is missing
from a real lock install.

Usage:
    python worker/tools/lock_closure.py [--report report.json]
                                        [--lock PATH] [--package DIR]
"""
from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from pathlib import Path

WORKER_ROOT = Path(__file__).resolve().parents[1]

# Distribution names that differ from the module they install. The fallback is
# a PEP 503 canonical match, so only real aliases belong here.
ALIASES = {
    "PIL": "pillow",
    "yaml": "pyyaml",
    "cv2": "opencv-python",
    "skimage": "scikit-image",
    "sklearn": "scikit-learn",
    "dateutil": "python-dateutil",
    "bs4": "beautifulsoup4",
    "attr": "attrs",
    "Crypto": "pycryptodome",
    "OpenSSL": "pyopenssl",
    # A shared namespace: judged by `ALIAS_PREFIXES`, never by the top-level
    # name alone.
    "google": "protobuf",
}

# Most aliases own their top-level name outright. `google` does not: it is a
# namespace several distributions share, and the pinned protobuf wheel ships
# exactly two module trees under it — `google/protobuf/` and
# `google/_upb/_message.abi3.so`, the upb extension protobuf's generated code
# imports. An alias listed here stands for its distribution only while every
# imported dotted name is inside one of these prefixes; any other `google.*`
# import falls back to the canonical top-level name and is reported as
# unpinned, because no pinned distribution is known to provide it.
ALIAS_PREFIXES = {"google": ("google.protobuf", "google._upb")}

# The package the bundle ships. Tests and tools are not in the payload.
FIRST_PARTY = {"retouch_ai_worker"}

# Only these two prove that the handler exists for a failed import. A handler
# that also catches `Exception` proves nothing about the dependency: it is the
# common defensive idiom around a hard import, and treating it as a refusal
# path would let an unpinned import pass.
IMPORT_ERRORS = {"ImportError", "ModuleNotFoundError"}

REQUIREMENT = re.compile(
    r"^(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)"
    r"(?P<extras>\[[^\]]*\])?"
    r"\s*==\s*(?P<version>[^\s;\\]+)\s*(?P<rest>;.*)?$")

HASH = re.compile(r"^--hash=(?P<algorithm>[a-z0-9]+):(?P<digest>[0-9a-fA-F]+)$")


def canonical(name: str) -> str:
    """PEP 503 normalisation: the only safe way to compare names."""
    return re.sub(r"[-_.]+", "-", name).strip().lower()


def distribution_for(module: str, names: set[str]) -> str:
    """The distribution a top-level module name stands for.

    `names` carries the full dotted imports the AST walk recorded. A scoped
    alias applies only when every one of them belongs to the distribution's
    module tree — for `google`, the prefixes in `ALIAS_PREFIXES`, which are
    the two trees the pinned protobuf wheel ships (`google.protobuf` and the
    `google._upb` extension). `import google.protobuf` is protobuf, but
    `import google.auth` is a different distribution nobody pinned, and the
    `google` namespace does not make it protobuf.
    """
    prefixes = ALIAS_PREFIXES.get(module)
    if prefixes:
        # `from google import protobuf` records both `google` (the module the
        # name came from) and `google.protobuf` (the bound name). The bare
        # top-level name is the namespace, not evidence of a second
        # distribution, so only the dotted names are judged. With no dotted
        # name at all (`import google`), the bare name must still prove itself.
        dotted = {name for name in names if name != module}
        if not all(
                any(name == prefix or name.startswith(prefix + ".")
                    for prefix in prefixes)
                for name in (dotted or names)):
            return canonical(module)
    return ALIASES.get(module, canonical(module))


class Lock:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.pins: dict[str, str] = {}
        self.hashes: dict[str, list[str]] = {}
        self.violations: list[str] = []


def read_lock(path: Path) -> Lock:
    lock = Lock(path)
    current: str | None = None
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if raw[:1].isspace():
            # Continuations carry the hashes. A trailing backslash is part of
            # the requirement syntax, not of the digest.
            line = line.rstrip("\\").strip()
            if current is None:
                lock.violations.append(
                    f"{path}:{number}: continuation outside a requirement")
                continue
            match = HASH.match(line)
            if not match:
                lock.violations.append(
                    f"{path}:{number}: only --hash continuations are allowed, "
                    f"found {line!r}")
                continue
            if match.group("algorithm") != "sha256":
                lock.violations.append(
                    f"{path}:{number}: only sha256 hashes are accepted, found "
                    f"{match.group('algorithm')}")
                continue
            lock.hashes[current].append(match.group("digest"))
            continue
        if line.startswith(("-", "http://", "https://", "git+", "file:")):
            lock.violations.append(
                f"{path}:{number}: the lock must be a flat list of pins, "
                f"found {line.split()[0]!r}")
            current = None
            continue
        match = REQUIREMENT.match(line.rstrip("\\").strip())
        if not match:
            lock.violations.append(
                f"{path}:{number}: not an exact pin: {line!r}")
            current = None
            continue
        if match.group("rest"):
            lock.violations.append(
                f"{path}:{number}: environment markers would make the set "
                f"depend on the machine: {line!r}")
        key = canonical(match.group("name"))
        if key in lock.pins:
            lock.violations.append(
                f"{path}:{number}: {match.group('name')} is pinned twice")
        lock.pins[key] = match.group("version")
        lock.hashes[key] = []
        current = key
    for key in sorted(lock.pins):
        digests = lock.hashes.get(key) or []
        if not digests:
            lock.violations.append(f"{path}: {key} carries no --hash")
        for digest in digests:
            if not re.fullmatch(r"[0-9a-f]{64}", digest):
                lock.violations.append(f"{path}: {key} has a malformed hash")
    return lock


def _handler_text(handler: ast.ExceptHandler) -> str:
    if handler.type is None:
        return "except:"
    return f"except {ast.unparse(handler.type)}"


def _import_guard(handler: ast.ExceptHandler) -> str | None:
    """Return the handler text if it guards an import, else None.

    The guard must catch only `ImportError`/`ModuleNotFoundError` (a tuple of
    those is fine). A bare `except:` or any handler that also names
    `Exception`/`BaseException` catches failures from the imported module
    itself, so it is not evidence that the dependency is optional.
    """
    if handler.type is None:
        return None
    types = (handler.type.elts if isinstance(handler.type, ast.Tuple)
             else [handler.type])
    names = []
    for node in types:
        if isinstance(node, ast.Name):
            names.append(node.id)
        elif isinstance(node, ast.Attribute):
            names.append(node.attr)
        else:
            return None
    if not names or any(name not in IMPORT_ERRORS for name in names):
        return None
    return _handler_text(handler)


def _import_call_kind(func: str) -> str | None:
    """Which importer a resolved call name is, or None if it is not one.

    `__import__` is the interpreter's importer and can only be called by that
    name, so an attribute of any module reaching it (`builtins.__import__`) is
    treated as one. `import_module` is importlib's: `_bind` gives its qualified
    spelling back in full, because that prefix is what proves which module owns
    it, and gives its bare spelling back unchanged for `_import_call_kind` to
    look up — see `IMPORT_FUNCS` for why the bare name is believed too. An
    attribute call on something that is not a plain name
    (`factory().import_module(...)`) is not believed either: `_bind` returns
    empty for it, so it cannot hide behind this rule.

    The returned value is also the parameter each function takes the module name
    in, which is why both are `name` today yet neither is assumed to be the
    other's spelling.
    """
    if func == "__import__" or func.endswith(".__import__"):
        return "__import__"
    if func in ("import_module", "importlib.import_module"):
        return "import_module"
    return None


def _literal_import_name(node: ast.Call, parameter: str) -> str | None:
    """The string literal a functional import names its module with.

    Positional first argument or the keyword the function documents — nothing
    else. A name this cannot read statically returns None so the caller can
    report the import as unresolvable rather than pretend it is absent.
    """
    if node.args and isinstance(node.args[0], ast.Constant) \
            and isinstance(node.args[0].value, str):
        return node.args[0].value
    for keyword in node.keywords:
        if keyword.arg == parameter and isinstance(keyword.value, ast.Constant) \
                and isinstance(keyword.value.value, str):
            return keyword.value.value
    return None


class _Imports(ast.NodeVisitor):
    """Collects top-level module names, remembering which are guarded.

    Walking the tree rather than reading lines is what reaches the lazy
    imports inside job methods (torch, transformers, mlx, mflux) — the exact
    place an unpinned dependency hides.

    A functional import (`__import__(...)`, `importlib.import_module(...)`) is
    recognised only when its name is a string literal reachable statically, in
    one of four spellings: positional (`import_module("cv2")`), keyword
    (`__import__(name="cv2")`), reached through a module attribute
    (`builtins.__import__("cv2")`), or reached through a name that this file
    bound with `from importlib import import_module`. Every other spelling — a
    name held in a variable, an attribute of something other than a known
    module, a call whose func is not a plain name or dotted name — is recorded
    as an entry in `dynamic` rather than dropped, so a gate can fail closed on
    an import it cannot read instead of reporting nothing at all.
    """

    # The two functions that import by name, keyed by the qualified name each is
    # reached by and valued with the parameter carrying the module name. Both
    # spellings of `import_module` are listed because `_bind` only rewrites a
    # bare local when its binding is seen before the call: a file that does
    # `import_module("x")` above `from importlib import import_module` still
    # binds that name at runtime, so the unqualified spelling is believed too.
    # A same-named helper defined in the audited package would be read as an
    # import — fail-safe in direction, and reported rather than skipped.
    IMPORT_FUNCS = {"__import__": "name",
                    "import_module": "name",
                    "importlib.import_module": "name"}

    def __init__(self, filename: str) -> None:
        self.filename = filename
        # `guarded` is True only for a strict import guard; `guards` records
        # which handler text supplied it so the report can name it.
        self.found: dict[str, dict[str, set]] = {}
        self.guards: set[str] = set()
        self.broad: set[str] = set()
        # Import-like calls this walk could not resolve to a literal name.
        self.dynamic: set[str] = set()
        # Local names bound by `from importlib import import_module`, plus the
        # aliases of modules imported for their attributes
        # (`import builtins` -> `builtins`). Both are per-file and track the
        # enclosing definition, because a name bound inside a function is not
        # visible outside it.
        self._func_alias: dict[str, str] = {}
        # Top-level names bound by `import x` / `import x.y [as z]`, used to
        # expand the module part of an attribute call. Kept separate from
        # `_func_alias`: `importlib` is both a package that may be imported and
        # the owner of `import_module`, and the two must not overwrite each
        # other.
        self._module_alias: dict[str, str] = {}

    def _bind(self, node: ast.AST) -> str:
        """The qualified name a call's `func` resolves to, else an empty string.

        A dotted importlib function reached through a submodule
        (`importlib.import_module`) is the importer itself, so it keeps its full
        dotted name — that prefix is what proves it. Any other attribute call is
        judged by the final name alone, because `__import__` can only be reached
        through the module that owns it.
        """
        if isinstance(node, ast.Name):
            return self._func_alias.get(node.id, node.id)
        if isinstance(node, ast.Attribute):
            if not isinstance(node.value, ast.Name):
                return ""
            if node.attr == "import_module":
                prefix = self._module_alias.get(node.value.id, node.value.id)
                return f"{prefix}.{node.attr}"
            return node.attr
        return ""

    def _note_dynamic(self, node: ast.Call) -> None:
        try:
            text = ast.unparse(node)[:80]
        except (AttributeError, RecursionError):  # pragma: no cover - py<3.9
            text = "<unprintable call>"
        self.dynamic.add(f"{self.filename}:{node.lineno}: {text}")

    def _record(self, names: list[str]) -> None:
        for name in names:
            top = name.split(".")[0]
            entry = self.found.setdefault(
                top, {"files": set(), "guarded": set(), "guards": set(),
                      "broad": set(), "names": set()})
            entry["files"].add(self.filename)
            entry["guarded"].add(bool(self.guards))
            entry["guards"] |= self.guards
            entry["broad"] |= self.broad
            # The full dotted name, kept for readers that need more than the
            # top-level module — `import_smoke.py` checks that each heavy
            # submodule it names is still imported somewhere.
            entry["names"].add(name)

    def visit_Import(self, node: ast.Import) -> None:
        self._record([alias.name for alias in node.names])
        for alias in node.names:
            # `import builtins` / `import importlib` make an attribute call on
            # that name a real importer; `import x.y as z` binds `z`.
            self._module_alias[alias.asname or alias.name.split(".")[0]] = \
                alias.name

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        if node.level == 0 and node.module:
            names = [node.module]
            names += [f"{node.module}.{alias.name}" for alias in node.names
                      if alias.name != "*"]
            self._record(names)
            if node.module == "importlib":
                for alias in node.names:
                    if alias.name in self.IMPORT_FUNCS:
                        self._func_alias[alias.asname or alias.name] = alias.name

    def visit_Call(self, node: ast.Call) -> None:
        func = self._bind(node.func)
        kind = _import_call_kind(func)
        if kind is not None:
            literal = _literal_import_name(node, self.IMPORT_FUNCS[kind])
            if literal is None:
                self._note_dynamic(node)
            else:
                self._record([literal])
        self.generic_visit(node)

    def visit_Try(self, node: ast.Try) -> None:
        guards = {guard for guard in
                  (_import_guard(handler) for handler in node.handlers)
                  if guard}
        broad = {_handler_text(handler) for handler in node.handlers
                 if _import_guard(handler) is None}
        previous = self.guards
        previous_broad = self.broad
        self.guards = previous | guards
        self.broad = previous_broad | broad
        for statement in node.body:
            self.visit(statement)
        self.guards = previous
        self.broad = previous_broad
        for handler in node.handlers:
            self.visit(handler)
        for statement in node.orelse + node.finalbody:
            self.visit(statement)

    def _visit_definition(self, node: ast.AST) -> None:
        """A handler around a definition does not cover code called from it.

        An import inside a function body runs when the function is called, not
        when the definition executes, so an enclosing `try` proves nothing
        about that import. The rule is fail-closed for every definition form:
        only a `try` inside the definition makes an import optional. A class
        body does run at definition time, which an enclosing handler would
        cover, but treating it the same keeps the classifier conservative for
        a shape nobody in the shipped package uses.

        The name bindings that decide whether a call is an importer are lexical
        too, so function-local `from importlib import import_module` cannot leak
        out to module level. Module-level `import x` aliases stay visible: they
        are the common case behind `builtins.__import__`.
        """
        guards, broad = self.guards, self.broad
        funcs = self._func_alias
        self.guards, self.broad = set(), set()
        self._func_alias = {}
        self.generic_visit(node)
        self.guards, self.broad = guards, broad
        self._func_alias = funcs

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self._visit_definition(node)

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self._visit_definition(node)

    def visit_Lambda(self, node: ast.Lambda) -> None:
        self._visit_definition(node)

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        self._visit_definition(node)


def imported_modules(package: Path) -> tuple[dict[str, dict[str, set]], set[str]]:
    """Return ({top-level module: entry}, import-like calls with no literal name).

    The second value is the set of unresolvable functional imports found in the
    package, each already prefixed with its file and line. A caller that only
    cares about names it can read ignores it; a gate uses it to fail closed.
    """
    found: dict[str, dict[str, set]] = {}
    dynamic: set[str] = set()
    for source in sorted(package.rglob("*.py")):
        visitor = _Imports(str(source.relative_to(package.parent)))
        visitor.visit(ast.parse(source.read_text(encoding="utf-8"),
                                filename=str(source)))
        dynamic |= visitor.dynamic
        for module, entry in visitor.found.items():
            merged = found.setdefault(
                module, {"files": set(), "guarded": set(), "guards": set(),
                         "broad": set(), "names": set()})
            merged["files"] |= entry["files"]
            merged["guarded"] |= entry["guarded"]
            merged["guards"] |= entry["guards"]
            merged["broad"] |= entry["broad"]
            merged["names"] |= entry["names"]
    return found, dynamic


def audit(lock: Lock, package: Path,
          *, allow_dynamic: bool = False
          ) -> tuple[list[str], dict[str, str], dict[str, str]]:
    """Return (violations, {module: distribution}, {module: why it is optional})."""
    try:
        stdlib = sys.stdlib_module_names
    except AttributeError:  # pragma: no cover - Python < 3.10
        stdlib = frozenset()
    violations: list[str] = []
    resolved: dict[str, str] = {}
    optional: dict[str, str] = {}
    imported, dynamic = imported_modules(package)
    if dynamic and not allow_dynamic:
        where = "; ".join(sorted(dynamic))
        violations.append(
            f"{where}: an import whose module name this walk cannot read "
            f"statically. It is not evidence of a missing pin, so it is "
            f"reported rather than skipped: name the module in a literal "
            f"`__import__(...)`/`importlib.import_module(...)` call, or pass "
            f"`allow_dynamic=True` where an unreadable import is expected")
    for module, entry in sorted(imported.items()):
        if module in stdlib or module in FIRST_PARTY:
            continue
        distribution = distribution_for(module, entry["names"])
        if canonical(distribution) in lock.pins:
            resolved[module] = distribution
            continue
        if entry["guarded"] == {True}:
            optional[module] = (
                "guarded by " + ", ".join(sorted(entry["guards"])))
            continue
        where = ", ".join(sorted(entry["files"])[:3])
        broad = ""
        if entry["broad"]:
            broad = (f"; its {', '.join(sorted(entry['broad']))} handler is "
                     f"not an import guard, so it does not make the import "
                     f"optional")
        violations.append(
            f"{where}: imports {module!r}, which no distribution in "
            f"{lock.path.name} provides{broad}")
    return violations, resolved, optional


def audit_report(report_path: Path, lock: Lock) -> tuple[list[str], list[str]]:
    """Compare a pip --report document with the lock. Returns (violations, notes)."""
    violations: list[str] = []
    notes: list[str] = []
    try:
        document = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return [f"{report_path}: unreadable report: {exc}"], notes
    entries = document.get("install")
    if not isinstance(entries, list) or not entries:
        return [f"{report_path}: no 'install' entries"], notes
    seen: dict[str, str] = {}
    wheels = 0
    sdists = 0
    for entry in entries:
        metadata = entry.get("metadata") or {}
        download = entry.get("download_info") or {}
        name, version = metadata.get("name"), metadata.get("version")
        if not name or not version:
            violations.append(f"{report_path}: an entry has no name or version")
            continue
        key = canonical(name)
        seen[key] = version
        if entry.get("is_direct"):
            violations.append(f"{report_path}: {name} was requested by URL")
        url = download.get("url") or ""
        if not url.startswith("https://"):
            violations.append(f"{report_path}: {name} has no https download URL")
        elif url.endswith(".whl"):
            wheels += 1
        else:
            sdists += 1
            notes.append(f"built from source at install time: "
                         f"{url.rsplit('/', 1)[-1]}")
    for key in sorted(set(seen) - set(lock.pins)):
        violations.append(
            f"{report_path}: the resolver added {key}, which the lock does not pin")
    for key in sorted(set(lock.pins) - set(seen)):
        violations.append(
            f"{report_path}: the lock pins {key}, the resolver did not pick it")
    for key in sorted(set(seen) & set(lock.pins)):
        if seen[key] != lock.pins[key]:
            violations.append(
                f"{report_path}: {key} resolved to {seen[key]}, "
                f"the lock pins {lock.pins[key]}")
    notes.insert(0, f"{len(entries)} distributions: {wheels} wheels, {sdists} sdists")
    return violations, notes


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lock", type=Path,
                        default=WORKER_ROOT / "requirements.lock")
    parser.add_argument("--package", type=Path,
                        default=WORKER_ROOT / "retouch_ai_worker")
    parser.add_argument("--test-lock", type=Path,
                        default=WORKER_ROOT / "requirements-test.lock")
    parser.add_argument("--report", type=Path,
                        help="pip install --dry-run --report document to verify")
    args = parser.parse_args(argv)

    lock = read_lock(args.lock)
    violations = list(lock.violations)
    import_violations, resolved, optional = audit(lock, args.package)
    violations.extend(import_violations)

    test_lock = read_lock(args.test_lock)
    violations.extend(test_lock.violations)
    for key, version in sorted(test_lock.pins.items()):
        if key not in lock.pins:
            violations.append(
                f"{args.test_lock.name}: {key} is not pinned by {args.lock.name}")
        elif lock.pins[key] != version:
            violations.append(
                f"{args.test_lock.name}: {key} {version} but the runtime "
                f"lock pins {lock.pins[key]}")

    notes: list[str] = []
    if args.report:
        report_violations, notes = audit_report(args.report, lock)
        violations.extend(report_violations)

    for line in notes:
        print(f"  · {line}")
    for module, why in sorted(optional.items()):
        print(f"  · optional, not a payload dependency: {module} ({why})")
    for violation in violations:
        print(f"  ✗ {violation}", file=sys.stderr)
    if violations:
        print(f"WORKER LOCK CLOSURE: FAIL ({len(violations)} problem(s))",
              file=sys.stderr)
        return 1
    modules = ", ".join(f"{m}->{d}" for m, d in sorted(resolved.items()))
    print(f"  · {len(lock.pins)} pinned distributions; shipped imports: {modules}")
    print(f"WORKER LOCK CLOSURE: PASS ({len(lock.pins)} distributions, "
          f"{len(resolved)} imported modules)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
