"""The archive must carry the locked set, not merely the right count.

The payload job used to accept `dist-info directories >= pinned requirements`.
The venv ships 68 directories for 67 pins (the extra is pip), so that inequality
passed — and it also passed for a duplicated, renamed or wrong-version
distribution, because none of those changes the count. These tests seed each of
those shapes in a small archive and assert the set comparison fails them, while
a complete archive still passes. The same `analyse` runs in CI against the real
`make-runtime.sh` archive.
"""
import importlib.util
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


def write_archive(path: Path, distributions: list[tuple[str, str, str]]) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for document in verify.ROOT_DOCUMENTS:
            archive.writestr(document, "placeholder")
        archive.writestr("bin/python3", "")
        archive.writestr("retouch_ai_worker/__init__.py", "")
        for package, version, directory in distributions:
            archive.writestr(
                f"site-packages/{directory}/METADATA",
                f"Metadata-Version: 2.1\nName: {package}\nVersion: {version}"
                f"\n\n")
            archive.writestr(f"site-packages/{directory}/RECORD", "")
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

    def _archive(self, distributions):
        path = self.root / "runtime.zip"
        write_archive(path, distributions)
        return path

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


if __name__ == "__main__":
    unittest.main()
