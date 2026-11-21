"""The suite's size has exactly one source.

`Tests/run-worker.sh` compares the `Ran N tests` line it observes with the
number in this file, and `macOS Integration` reads the same number for its
verdict assertion. This test closes the loop from the other side: it loads
the suite the way `run-worker.sh` does and fails when discovery finds a
different count, so adding or deleting a test without updating the one
expected value cannot pass locally.
"""
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
REPO = TESTS.parents[1]
EXPECTED = REPO / "Tests" / "expected-worker-tests.txt"


class SuiteCountTest(unittest.TestCase):
    def test_discovery_matches_the_single_expected_value(self):
        expected = EXPECTED.read_text(encoding="utf-8").strip()
        self.assertRegex(expected, r"^[0-9]+$",
                         f"{EXPECTED} must hold a bare integer")
        discovered = unittest.TestLoader().discover(str(TESTS))
        actual = discovered.countTestCases()
        self.assertEqual(
            actual, int(expected),
            "the discovered suite and Tests/expected-worker-tests.txt "
            "disagree; update that file to the measured count")


if __name__ == "__main__":
    unittest.main()
