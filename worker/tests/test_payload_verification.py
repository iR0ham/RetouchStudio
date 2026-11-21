"""The archive must carry the locked set, not merely the right count.

The payload job used to accept `dist-info directories >= pinned requirements`.
The venv ships 68 directories for 67 pins (the extra is pip), so that inequality
passed — and it also passed for a duplicated, renamed or wrong-version
distribution, because none of those changes the count. These tests seed each of
those shapes in a small archive and assert the set comparison fails them, while
a complete archive still passes. The same `analyse` runs in CI against the real
`make-runtime.sh` archive.
"""
import contextlib
import importlib.util
import io
import tempfile
import unittest
import zipfile
from pathlib import Path

WORKER = Path(__file__).resolve().parents[1]
TOOL = WORKER / "tools" / "verify_payload.py"

_spec = importlib.util.spec_from_file_location("verify_payload", TOOL)
verify = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verify)

PIP_VERSION = "25.2"
HASH = "a" * 64


def write_lock(path: Path, pins: dict[str, str]) -> None:
    lines = []
    for name, version in pins.items():
        lines.append(f"{name}=={version} \\")
        lines.append(f"    --hash=sha256:{HASH}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_archive(path: Path, distributions: list[tuple[str, str, str]],
                  *, documents: bool = True, licences: bool = True,
                  interpreter: bool = True, package: bool = True) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        if documents:
            for document in verify.ROOT_DOCUMENTS:
                archive.writestr(document, "placeholder")
        if interpreter:
            archive.writestr("bin/python3", "")
        if package:
            archive.writestr("retouch_ai_worker/__init__.py", "")
        for name, version, directory in distributions:
            archive.writestr(
                f"site-packages/{directory}/METADATA",
                f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}"
                f"\n\n")
            archive.writestr(f"site-packages/{directory}/RECORD", "")
            if licences:
                archive.writestr(
                    f"site-packages/{directory}/licenses/LICENSE", "licence")


class PayloadVerificationTest(unittest.TestCase):
    def setUp(self):
        self._scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self._scratch.cleanup)
        self.root = Path(self._scratch.name)
        self.lock_path = self.root / "requirements.lock"
        write_lock(self.lock_path, {"alpha": "1.0", "beta": "2.0"})
        self.lock = verify.lock_closure.read_lock(self.lock_path)

    def _archive(self, distributions, **options):
        path = self.root / "runtime.zip"
        write_archive(path, distributions, **options)
        return path

    def _run(self, path):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = verify.main(["--archive", str(path),
                                "--lock", str(self.lock_path),
                                "--pip-version", PIP_VERSION])
        return code, out.getvalue(), err.getvalue()

    def test_a_complete_archive_passes(self):
        path = self._archive([
            ("alpha", "1.0", "alpha-1.0.dist-info"),
            ("beta", "2.0", "beta-2.0.dist-info"),
            ("pip", PIP_VERSION, f"pip-{PIP_VERSION}.dist-info"),
        ])
        violations, counts = verify.analyse(path, self.lock, PIP_VERSION)
        self.assertEqual(violations, [])
        self.assertEqual(counts["distinfos"], 3)

    def test_case_preserving_directory_names_pass(self):
        """Wheels keep the project's case: PyYAML-6.0.2.dist-info is valid.

        The check compares the PEP 503 name and the version, not the string,
        so a future strict comparison cannot fail a real archive.
        """
        lock_path = self.root / "case-lock"
        write_lock(lock_path, {"PyYAML": "6.0.2"})
        lock = verify.lock_closure.read_lock(lock_path)
        path = self._archive([
            ("PyYAML", "6.0.2", "PyYAML-6.0.2.dist-info"),
            ("pip", PIP_VERSION, f"pip-{PIP_VERSION}.dist-info"),
        ])
        violations, _counts = verify.analyse(path, lock, PIP_VERSION)
        self.assertEqual(violations, [])

    def test_a_matching_count_can_hide_a_wrong_version(self):
        """Seeded defect: the old count check passed this archive."""
        path = self._archive([
            ("alpha", "1.0", "alpha-1.0.dist-info"),
            ("beta", "2.1", "beta-2.1.dist-info"),
            ("pip", PIP_VERSION, f"pip-{PIP_VERSION}.dist-info"),
        ])
        with zipfile.ZipFile(path) as archive:
            count = len(verify._dist_info_dirs(archive.namelist()))
        self.assertEqual(count, 3)
        self.assertGreaterEqual(count, len(self.lock.pins),
                                "the old count comparison accepts this")
        violations, _counts = verify.analyse(path, self.lock, PIP_VERSION)
        self.assertTrue(any("beta" in violation for violation in violations))
        self.assertTrue(any("2.1" in violation for violation in violations))

    def test_a_matching_count_can_hide_a_rename(self):
        """A renamed directory and a renamed distribution both fail."""
        renamed_directory = self._archive([
            ("alpha", "1.0", "alpha-9.9.dist-info"),
            ("beta", "2.0", "beta-2.0.dist-info"),
            ("pip", PIP_VERSION, f"pip-{PIP_VERSION}.dist-info"),
        ])
        violations, _counts = verify.analyse(
            renamed_directory, self.lock, PIP_VERSION)
        self.assertTrue(any("does not match its METADATA" in violation
                            for violation in violations))
        renamed_package = self._archive([
            ("gamma", "1.0", "gamma-1.0.dist-info"),
            ("beta", "2.0", "beta-2.0.dist-info"),
            ("pip", PIP_VERSION, f"pip-{PIP_VERSION}.dist-info"),
        ])
        violations, _counts = verify.analyse(
            renamed_package, self.lock, PIP_VERSION)
        self.assertTrue(any("gamma" in violation for violation in violations))
        self.assertTrue(any("alpha" in violation for violation in violations))

    def test_only_the_pip_allowance_is_allowed(self):
        extra = self._archive([
            ("alpha", "1.0", "alpha-1.0.dist-info"),
            ("beta", "2.0", "beta-2.0.dist-info"),
            ("pip", PIP_VERSION, f"pip-{PIP_VERSION}.dist-info"),
            ("sneaky", "1.0", "sneaky-1.0.dist-info"),
        ])
        violations, _counts = verify.analyse(extra, self.lock, PIP_VERSION)
        self.assertTrue(any("sneaky" in violation for violation in violations))
        wrong_pip = self._archive([
            ("alpha", "1.0", "alpha-1.0.dist-info"),
            ("beta", "2.0", "beta-2.0.dist-info"),
            ("pip", "24.0", "pip-24.0.dist-info"),
        ])
        violations, _counts = verify.analyse(
            wrong_pip, self.lock, PIP_VERSION)
        self.assertTrue(any("allowance" in violation for violation in violations))
        without_pip = self._archive([
            ("alpha", "1.0", "alpha-1.0.dist-info"),
            ("beta", "2.0", "beta-2.0.dist-info"),
        ])
        violations, _counts = verify.analyse(
            without_pip, self.lock, PIP_VERSION)
        self.assertTrue(any("no pip dist-info" in violation
                            for violation in violations))

    def test_zero_licences_is_reported_not_an_empty_process(self):
        """AC-nolicences: the shell step died in `grep -c` before its check.

        The Python verifier has no pipe to abort: it counts zero licence
        files and says so, and `main` exits 1 with a non-empty verdict.
        """
        path = self._archive([
            ("alpha", "1.0", "alpha-1.0.dist-info"),
            ("beta", "2.0", "beta-2.0.dist-info"),
            ("pip", PIP_VERSION, f"pip-{PIP_VERSION}.dist-info"),
        ], licences=False)
        violations, counts = verify.analyse(path, self.lock, PIP_VERSION)
        self.assertEqual(counts["licences"], 0)
        self.assertIn("no licence file survived into the archive", violations)
        code, out, err = self._run(path)
        self.assertEqual(code, 1)
        self.assertIn("licence files inside dist-info: 0", out)
        self.assertIn("no licence file survived into the archive", err)
        self.assertIn("WORKER PAYLOAD: FAIL", err)

    def test_an_empty_archive_is_explicit(self):
        """No dist-info at all: every missing thing is named, no traceback."""
        path = self.root / "empty.zip"
        write_archive(path, [], documents=False, interpreter=False,
                      package=False)
        violations, counts = verify.analyse(path, self.lock, PIP_VERSION)
        self.assertEqual(counts["distinfos"], 0)
        for document in verify.ROOT_DOCUMENTS:
            self.assertIn(f"the archive has no {document} at its root",
                          violations)
        self.assertIn("the archive has no bundled interpreter (bin/python3)",
                      violations)
        self.assertIn("the archive carries no retouch_ai_worker package",
                      violations)
        self.assertIn("no licence file survived into the archive", violations)
        self.assertIn("alpha: the lock pins it, the archive does not carry it",
                      violations)
        self.assertIn("the archive carries no pip dist-info, so the one "
                      "documented allowance cannot be verified", violations)
        code, _out, err = self._run(path)
        self.assertEqual(code, 1)
        self.assertIn("WORKER PAYLOAD: FAIL", err)

    def test_fewer_dist_info_than_pins_is_a_failure(self):
        """AC-short: the count control. Fewer entries than pins."""
        path = self._archive([
            ("alpha", "1.0", "alpha-1.0.dist-info"),
            ("pip", PIP_VERSION, f"pip-{PIP_VERSION}.dist-info"),
        ])
        violations, counts = verify.analyse(path, self.lock, PIP_VERSION)
        self.assertLess(counts["distinfos"], len(self.lock.pins) + 1)
        self.assertIn("beta: the lock pins it, the archive does not carry it",
                      violations)

    def test_missing_root_documents_are_named(self):
        """AC-nodocs: each absent root document gets its own message."""
        path = self._archive([
            ("alpha", "1.0", "alpha-1.0.dist-info"),
            ("beta", "2.0", "beta-2.0.dist-info"),
            ("pip", PIP_VERSION, f"pip-{PIP_VERSION}.dist-info"),
        ], documents=False)
        violations, _counts = verify.analyse(path, self.lock, PIP_VERSION)
        for document in verify.ROOT_DOCUMENTS:
            self.assertIn(f"the archive has no {document} at its root",
                          violations)


if __name__ == "__main__":
    unittest.main()
