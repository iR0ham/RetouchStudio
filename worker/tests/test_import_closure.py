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
import importlib.util
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
