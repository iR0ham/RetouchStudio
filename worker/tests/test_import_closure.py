"""The shipping runtime must close over what the worker imports (W5-16).

`requirements-test.lock` holds numpy and pillow only, so the protocol suite
never imports torch, mlx, mflux, onnxruntime or transformers. That split is
right for speed and it is exactly how an unpinned import once reached the
owner's machine: the engine imported `cv2`, the tests passed on an
environment that was not the environment that ships, and the break surfaced
as an ImportError behind an AI feature.

These tests read the lock and the shipped package as files. They need no
wheels, no download and no GPU, and they cannot be satisfied by a test-only
environment. An import wrapped in `except ImportError` (or
`ModuleNotFoundError`) is a refusal path (`sam2` says "this worker cannot run
SAM 2.1"), not a payload dependency, so it is reported and exempt; an
unguarded import, or one behind a broader handler such as `except Exception:`
or a bare `except:`, is required to be pinned. The broad-handler cases are
seeded below because treating them as exempt was the fail-open path: the
idiom is common around a hard import, and a missing pin behind it would have
passed CI.
"""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

WORKER = Path(__file__).resolve().parents[1]
TOOL = WORKER / "tools" / "lock_closure.py"

_spec = importlib.util.spec_from_file_location("lock_closure", TOOL)
closure = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(closure)


class ImportClosureTest(unittest.TestCase):
    def test_shipped_imports_are_all_pinned(self):
        lock = closure.read_lock(WORKER / "requirements.lock")
        violations, resolved, _optional = closure.audit(
            lock, WORKER / "retouch_ai_worker")
        self.assertEqual(
            violations, [],
            "the shipped package imports a module no lock entry provides; "
            "it would fail as an ImportError on the owner's machine")
        # The lazy engine imports are the ones a test-only environment cannot
        # reach, so a vacuous pass (nothing found) is a failure too.
        self.assertTrue(resolved, "no third-party import was found to check")
        for module, distribution in resolved.items():
            self.assertIn(closure.canonical(distribution), lock.pins,
                          f"{module} resolved to an unpinned {distribution}")

    def test_guarded_imports_are_exempt_and_unguarded_imports_are_not(self):
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(
                "try:\n"
                "    import sam2\n"
                "except ImportError:\n"
                "    sam2 = None\n"
                "if True:\n"
                "    import torch\n"
                "    lazy = torch\n",
                encoding="utf-8")
            lock = closure.read_lock(WORKER / "requirements.lock")
            violations, resolved, optional = closure.audit(lock, package)
        # Torch is pinned, so the unguarded lazy import passes here; the
        # missing-pin case is the cv2 one, exercised below on the same tree.
        self.assertIn("torch", resolved)
        self.assertIn("sam2", optional)
        self.assertEqual(violations, [])
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text("import cv2\n", encoding="utf-8")
            violations, _resolved, _optional = closure.audit(lock, package)
        self.assertEqual(len(violations), 1)
        self.assertIn("cv2", violations[0])

    def test_broad_handlers_do_not_exempt_a_hard_import(self):
        """`except Exception:` and bare `except:` are not import guards.

        Seeded defect: an unpinned module imported inside the common
        defensive idiom. The old classifier counted it as optional; these
        assert it is a violation, and that a pinned module in the same
        position is still resolved (the handler does not hide it either).
        """
        sources = {
            "except Exception:": (
                "try:\n"
                "    import cv2\n"
                "except Exception:\n"
                "    cv2 = None\n"),
            "bare except:": (
                "try:\n"
                "    import cv2\n"
                "except:\n"
                "    cv2 = None\n"),
            "except (Exception, ImportError):": (
                "try:\n"
                "    import cv2\n"
                "except (Exception, ImportError):\n"
                "    cv2 = None\n"),
        }
        lock = closure.read_lock(WORKER / "requirements.lock")
        for label, source in sources.items():
            with self.subTest(handler=label):
                with tempfile.TemporaryDirectory() as scratch:
                    package = Path(scratch) / "pkg"
                    package.mkdir()
                    (package / "engine.py").write_text(source,
                                                       encoding="utf-8")
                    violations, resolved, optional = closure.audit(
                        lock, package)
                self.assertNotIn("cv2", optional,
                                 "a broad handler must not be reported as a "
                                 "deliberate refusal path")
                self.assertNotIn("cv2", resolved)
                self.assertEqual(len(violations), 1)
                self.assertIn("cv2", violations[0])
                self.assertIn("not an import guard", violations[0])
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(
                "try:\n"
                "    import torch\n"
                "except Exception:\n"
                "    torch = None\n",
                encoding="utf-8")
            violations, resolved, optional = closure.audit(lock, package)
        self.assertIn("torch", resolved)
        self.assertNotIn("torch", optional)
        self.assertEqual(violations, [])

    def test_guarded_import_reports_the_real_handler(self):
        """The exemption names the handler that supplied it.

        The failure this prevents: a message that always said "guarded by
        except ImportError" while the matching logic accepted anything.
        """
        lock = closure.read_lock(WORKER / "requirements.lock")
        cases = {
            "except ImportError:": "except ImportError",
            "except ModuleNotFoundError as exc:": (
                "except ModuleNotFoundError"),
            "except (ImportError, ModuleNotFoundError):": (
                "except (ImportError, ModuleNotFoundError)"),
        }
        for header, expected in cases.items():
            with self.subTest(handler=header):
                with tempfile.TemporaryDirectory() as scratch:
                    package = Path(scratch) / "pkg"
                    package.mkdir()
                    (package / "engine.py").write_text(
                        "try:\n"
                        "    import sam2\n"
                        f"{header}\n"
                        "    sam2 = None\n",
                        encoding="utf-8")
                    violations, _resolved, optional = closure.audit(
                        lock, package)
                self.assertEqual(violations, [])
                self.assertEqual(optional.get("sam2"),
                                 f"guarded by {expected}")

    def test_unguarded_and_mixed_occurrences_are_violations(self):
        """B3/B4 seedings, side by side.

        B3 is the control: an unguarded unpinned import must fail. B4 is the
        one the old classifier also got wrong in the interesting way — the
        same module imported unguarded in one file and behind a real guard in
        another. One unguarded occurrence is enough: the import is required,
        and the `optional` report must not absorb it.
        """
        lock = closure.read_lock(WORKER / "requirements.lock")
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text("import cv2\n",
                                               encoding="utf-8")
            violations, resolved, optional = closure.audit(lock, package)
        self.assertEqual(len(violations), 1)  # B3
        self.assertIn("cv2", violations[0])
        self.assertNotIn("not an import guard", violations[0],
                         "a bare unguarded import has no handler to blame")
        self.assertNotIn("cv2", optional)
        self.assertNotIn("cv2", resolved)

        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "guarded.py").write_text(
                "try:\n"
                "    import cv2\n"
                "except ImportError:\n"
                "    cv2 = None\n",
                encoding="utf-8")
            (package / "unguarded.py").write_text("import cv2\n",
                                                  encoding="utf-8")
            violations, resolved, optional = closure.audit(lock, package)
        self.assertEqual(len(violations), 1)  # B4
        self.assertIn("cv2", violations[0])
        self.assertNotIn("cv2", optional)

    def test_resolver_report_is_compared_with_the_lock_exactly(self):
        """A4: a pip `--dry-run --report` document against the lock.

        A report that matches the pins is evidence the lock resolves on its
        own; an extra distribution means pip picked something the lock does
        not pin, an omitted pin means the lock names something pip never
        installs, and a different version means the report and the lock
        describe different environments. The same comparison runs through
        `main`, because that is the command the CI step uses.
        """
        pins = {"numpy": "2.5.4", "pillow": "12.0.0"}

        def entry(name, version):
            wheel = (f"{name}-{version}-cp311-cp311-macosx_11_0_arm64.whl")
            return {
                "metadata": {"name": name, "version": version},
                "download_info": {
                    "url": f"https://files.pythonhosted.org/packages/{wheel}"},
                "is_direct": False,
            }

        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            lock_path = scratch / "requirements.lock"
            lines = []
            for name, version in pins.items():
                lines.append(f"{name}=={version} \\")
                lines.append(f"    --hash=sha256:{'0' * 64}")
            lock_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            lock = closure.read_lock(lock_path)
            self.assertEqual(lock.violations, [])
            package = scratch / "pkg"
            package.mkdir()
            report = scratch / "report.json"

            def write_report(entries):
                report.write_text(json.dumps({"install": entries}),
                                  encoding="utf-8")

            def run_main():
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), \
                        contextlib.redirect_stderr(err):
                    code = closure.main([
                        "--lock", str(lock_path),
                        "--package", str(package),
                        "--test-lock", str(lock_path),
                        "--report", str(report)])
                return code, out.getvalue(), err.getvalue()

            exact = [entry("numpy", "2.5.4"), entry("pillow", "12.0.0")]
            write_report(exact)
            violations, notes = closure.audit_report(report, lock)
            self.assertEqual(violations, [])
            self.assertEqual(notes[0], "2 distributions: 2 wheels, 0 sdists")
            code, stdout, _stderr = run_main()
            self.assertEqual(code, 0)
            self.assertIn("WORKER LOCK CLOSURE: PASS (2 distributions, "
                          "0 imported modules)", stdout)

            write_report(exact + [entry("evilpkg", "1.0")])
            violations, _notes = closure.audit_report(report, lock)
            self.assertEqual(len(violations), 1)
            self.assertIn("the resolver added evilpkg, which the lock does "
                          "not pin", violations[0])
            code, _stdout, stderr = run_main()
            self.assertEqual(code, 1)
            self.assertIn("WORKER LOCK CLOSURE: FAIL (1 problem(s))", stderr)

            write_report([entry("numpy", "2.5.4")])
            violations, _notes = closure.audit_report(report, lock)
            self.assertEqual(len(violations), 1)
            self.assertIn("the lock pins pillow, the resolver did not pick it",
                          violations[0])

            write_report([entry("numpy", "9.9.9"), entry("pillow", "12.0.0")])
            violations, _notes = closure.audit_report(report, lock)
            self.assertEqual(len(violations), 1)
            self.assertIn("numpy resolved to 9.9.9, the lock pins 2.5.4",
                          violations[0])

    def test_a_namespace_import_outside_the_aliased_distribution_is_unpinned(self):
        """`google.auth` is not protobuf merely because both live under google.

        The alias map is keyed on the top-level name, so a namespace shared by
        several distributions used to collapse into its one alias entry:
        `import google.auth` resolved to protobuf and both gates passed. The
        alias now applies only inside `google.protobuf`.
        """
        lock = closure.read_lock(WORKER / "requirements.lock")
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text("import google.auth\n",
                                               encoding="utf-8")
            violations, resolved, optional = closure.audit(lock, package)
        self.assertEqual(len(violations), 1)
        self.assertIn("google", violations[0])
        self.assertNotIn("google", optional)
        self.assertNotIn("google", resolved)

        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(
                "import google.protobuf\nimport google.auth\n",
                encoding="utf-8")
            violations, resolved, optional = closure.audit(lock, package)
        self.assertEqual(len(violations), 1,
                         "one outside name taints the whole top-level module")
        self.assertNotIn("google", resolved)

        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text("import google.protobuf\n",
                                               encoding="utf-8")
            violations, resolved, optional = closure.audit(lock, package)
        self.assertEqual(violations, [])
        self.assertEqual(resolved.get("google"), "protobuf")
        self.assertEqual(optional, {})

        # `from google import protobuf` records the bare module name too; that
        # is not a second distribution and must not become a false positive.
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(
                "from google import protobuf\n", encoding="utf-8")
            violations, resolved, optional = closure.audit(lock, package)
        self.assertEqual(violations, [])
        self.assertEqual(resolved.get("google"), "protobuf")

        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(
                "from google import auth\n", encoding="utf-8")
            violations, resolved, optional = closure.audit(lock, package)
        self.assertEqual(len(violations), 1,
                         "`from google import auth` is not protobuf either")
        self.assertNotIn("google", resolved)

    def test_a_guard_around_a_definition_does_not_reach_into_it(self):
        """An enclosing `try` does not guard an import the definition runs later.

        `try:\n def load(): import cv2\nexcept ImportError:` used to mark cv2
        optional even though the import executes when `load()` is called,
        possibly outside the handler. Fail-closed: only a `try` inside the
        definition can do that.
        """
        lock = closure.read_lock(WORKER / "requirements.lock")
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(
                "try:\n"
                "    def load():\n"
                "        import cv2\n"
                "except ImportError:\n"
                "    pass\n"
                "load()\n",
                encoding="utf-8")
            violations, resolved, optional = closure.audit(lock, package)
        self.assertEqual(len(violations), 1)
        self.assertIn("cv2", violations[0])
        self.assertNotIn("cv2", optional)
        self.assertNotIn("cv2", resolved)

        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(
                "def load():\n"
                "    try:\n"
                "        import sam2\n"
                "    except ImportError:\n"
                "        return None\n"
                "load()\n",
                encoding="utf-8")
            violations, resolved, optional = closure.audit(lock, package)
        self.assertEqual(violations, [])
        self.assertIn("sam2", optional)
        self.assertNotIn("sam2", resolved)

    def test_the_upb_tree_of_the_pinned_protobuf_wheel_is_protobuf(self):
        """`google._upb._message` is protobuf's own extension module (F8).

        The rule for a shared namespace is "every imported dotted name must be
        inside a prefix the pinned distribution actually ships". Measured on
        the pinned wheel recorded in `requirements.lock`
        (`protobuf-7.36.2-cp310-abi3-macosx_10_9_universal2.whl`, 456,039 B,
        listed by `unzip -l` on the download), the only two trees under
        `google/` are `google/protobuf/` and `google/_upb/_message.abi3.so`, so
        both are prefixes here, and the second one used to be a false
        positive: `import google._upb._message`
        resolved to canonical `google` and was reported as unpinned. Every
        other `google.*` name still has exactly one violation.
        """
        lock = closure.read_lock(WORKER / "requirements.lock")
        self.assertIn("protobuf", lock.pins)
        self.assertNotIn("google", lock.pins)

        # Inside a shipped prefix: protobuf, no violation.
        for source in ("import google._upb._message\n",
                       "from google._upb import _message\n"):
            with self.subTest(source=source.strip()):
                with tempfile.TemporaryDirectory() as scratch:
                    package = Path(scratch) / "pkg"
                    package.mkdir()
                    (package / "engine.py").write_text(source, encoding="utf-8")
                    violations, resolved, optional = closure.audit(lock, package)
                self.assertEqual(violations, [])
                self.assertEqual(resolved.get("google"), "protobuf")
                self.assertEqual(optional, {})

        # Both prefixes together are still one distribution.
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(
                "import google.protobuf\nimport google._upb._message\n",
                encoding="utf-8")
            violations, resolved, _optional = closure.audit(lock, package)
        self.assertEqual(violations, [])
        self.assertEqual(resolved.get("google"), "protobuf")

        # Outside every prefix: exactly one violation each, fail-closed.
        outside = {
            "import google.auth\n": {"google"},
            "import google.cloud.storage\n": {"google"},
            "from google import auth\n": {"google"},
            "import google\n": {"google"},
        }
        for source, expected_names in outside.items():
            with self.subTest(source=source.strip()):
                with tempfile.TemporaryDirectory() as scratch:
                    package = Path(scratch) / "pkg"
                    package.mkdir()
                    (package / "engine.py").write_text(source, encoding="utf-8")
                    violations, resolved, optional = closure.audit(lock, package)
                self.assertEqual(len(violations), 1, f"{source!r} -> {violations}")
                self.assertIn("google", violations[0])
                self.assertEqual(set(resolved) & expected_names, set())
                self.assertEqual(optional, {})

        # A prefix and an outside name together still taint the top-level.
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(
                "import google._upb._message\nimport google.auth\n",
                encoding="utf-8")
            violations, resolved, _optional = closure.audit(lock, package)
        self.assertEqual(len(violations), 1)
        self.assertNotIn("google", resolved)

    def _audit_source(self, lock, source: str):
        """Audit one file of source the way the gate sees it."""
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(source, encoding="utf-8")
            return closure.audit(lock, package)

    def test_a_functional_import_is_an_import_whatever_its_spelling(self):
        """`import cv2` and a call that imports `cv2` are the same dependency.

        The walk used to recognise only a positional string literal passed to
        `__import__` or `importlib.import_module`. Three other spellings were
        measured to produce no violation, no target and no unpinned entry — an
        unpinned dependency could be added to the shipped package and pass every
        gate with `from importlib import import_module` plus
        `import_module("cv2")`. Each spelling below is now audited on a lock
        without a `cv2` pin and must name `cv2`.
        """
        lock = closure.read_lock(WORKER / "requirements.lock")
        self.assertNotIn("cv2", lock.pins)
        forms = {
            # The reviewer's three escapes.
            "aliased import_module":
                "from importlib import import_module\nimport_module('cv2')\n",
            "keyword argument": "__import__(name='cv2')\n",
            "builtins attribute":
                "import builtins\nbuiltins.__import__('cv2')\n",
            # Spellings that already worked; pinned so a refactor cannot trade
            # one escape for another.
            "dotted positional":
                "import importlib\nimportlib.import_module('cv2')\n",
            "dunder positional": "__import__('cv2')\n",
            "aliased module":
                "from importlib import import_module as imp\nimp('cv2')\n",
            "inside a function":
                "from importlib import import_module\n"
                "def job():\n    return import_module('cv2')\n",
        }
        for label, source in forms.items():
            with self.subTest(form=label):
                violations, resolved, optional = self._audit_source(lock, source)
                self.assertEqual(len(violations), 1, f"{label}: {violations}")
                self.assertIn("cv2", violations[0])
                self.assertEqual(optional, {})
                self.assertNotIn("cv2", resolved)

    def test_a_pinned_functional_import_resolves(self):
        """The point is to see the import, not to forbid the spelling."""
        lock = closure.read_lock(WORKER / "requirements.lock")
        self.assertIn("numpy", lock.pins)
        violations, resolved, _optional = self._audit_source(
            lock, "from importlib import import_module\nimport_module('numpy')\n")
        self.assertEqual(violations, [])
        self.assertEqual(resolved.get("numpy"), "numpy")

    def test_an_unreadable_functional_import_fails_closed_and_can_be_allowed(self):
        """A name the walk cannot read is reported, never dropped.

        Failing closed is what stops the four recognised spellings from becoming
        a whitelist to dodge: `import_module(module_variable)` and
        `getattr(importlib, "import_module")(...)` have no literal to audit, so
        each produces a violation naming its file and line. That is also why the
        real tree must stay clean without the opt-out — nothing shipped imports a
        computed name — and `allow_dynamic=True` exists for a caller that expects
        one.
        """
        lock = closure.read_lock(WORKER / "requirements.lock")
        unreadable = {
            "variable name":
                "from importlib import import_module\nimport_module(which)\n",
            "f-string name":
                "from importlib import import_module\n"
                "import_module(f'cv{2}')\n",
            "dunder attribute of a module":
                "import builtins\nbuiltins.__import__(which)\n",
            "keyword variable": "__import__(name=which)\n",
        }
        for label, source in unreadable.items():
            with self.subTest(form=label):
                violations, _resolved, _optional = self._audit_source(lock, source)
                self.assertEqual(len(violations), 1, f"{label}: {violations}")
                self.assertIn("engine.py:", violations[0])
                self.assertIn("cannot read", violations[0])

        # The one shape that is still invisible, pinned so the limit stays
        # documented rather than quietly widened: hiding the importer itself
        # behind a computation leaves no function name to classify.
        hidden = ("import importlib\n"
                  "getattr(importlib, 'import_module')('cv2')\n")
        violations, _resolved, _optional = self._audit_source(lock, hidden)
        self.assertEqual(violations, [],
                         "the walk cannot know this call imports anything")
        # The opt-out is per-call-site evidence, not a global mute: with it the
        # file is silent, without it the same file fails.
        source = unreadable["variable name"]
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "pkg"
            package.mkdir()
            (package / "engine.py").write_text(source, encoding="utf-8")
            violations, _resolved, _optional = closure.audit(
                lock, package, allow_dynamic=True)
        self.assertEqual(violations, [])

        # Nothing in the shipped package needs the opt-out.
        strict, resolved, _optional = closure.audit(
            lock, WORKER / "retouch_ai_worker")
        self.assertEqual(strict, [])
        self.assertTrue(resolved)

    def test_lock_is_exact_hashed_and_covers_the_test_lock(self):
        lock = closure.read_lock(WORKER / "requirements.lock")
        self.assertEqual(lock.violations, [])
        self.assertGreater(len(lock.pins), 0)
        for key, digests in lock.hashes.items():
            self.assertTrue(digests, f"{key} has no SHA-256")
        test_lock = closure.read_lock(WORKER / "requirements-test.lock")
        self.assertEqual(test_lock.violations, [])
        for key, version in test_lock.pins.items():
            self.assertIn(key, lock.pins,
                          f"{key} is in the test environment, not the payload")
            self.assertEqual(lock.pins[key], version,
                             f"{key} is {version} under test, "
                             f"{lock.pins[key]} in the payload")


if __name__ == "__main__":
    unittest.main()
