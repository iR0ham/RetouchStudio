"""The suite's size has exactly one source.

`Tests/run-worker.sh` compares the `Ran N tests` line it observes with the
number in this file, and `macOS Integration` reads the same number for its
verdict assertion. This test closes the loop from the other side: it loads
the suite the way `run-worker.sh` does and fails when discovery finds a
different count, so adding or deleting a test without updating the one
expected value cannot pass locally.

What is pinned is the *number of discovered cases*, which is narrower than "the
contents of the suite". A rename and a one-for-one replacement leave that number
alone, so neither needs the file edited — but an unimportable test file does not
escape: `discover` appends a synthetic `_FailedTest`, so the count moves and this
test fails. The gap worth naming is a case that is discovered yet never runs,
because `@unittest.skip` keeps it in `countTestCases()`: a test can be
neutralised without the number moving at all. The second check below pins what
discovery reports for a broken file, and the first asserts its error list is empty
so the reason is named rather than left as a bare off-by-one.
"""
import tempfile
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
        loader = unittest.TestLoader()
        discovered = loader.discover(str(TESTS))
        # A test file that fails to import is not a case: `discover` records it
        # in `loader.errors` and the run still reports the number it found. That
        # would let a whole module disappear while this assertion stayed green,
        # so discovery has to be clean before its size means anything.
        self.assertEqual(
            list(loader.errors), [],
            "a worker test file failed to import, so the suite count below "
            "describes a smaller run than the branch ships")
        actual = discovered.countTestCases()
        self.assertEqual(
            actual, int(expected),
            "the discovered suite and Tests/expected-worker-tests.txt "
            "disagree; update that file to the measured count")

    def test_a_broken_test_file_is_reported_as_a_discovery_error(self):
        """The guard above has something to catch, proved on a real failure.

        `unittest` keeps the shape of this contract internal, so it is pinned
        here against a scratch tree rather than assumed. Measured: a file that
        raises on import contributes no cases from itself, but the loader appends
        one synthetic `_FailedTest`, so `countTestCases()` goes up by one while
        `loader.errors` gains an entry naming the module. Both halves matter — the
        count moves, so `run-worker.sh` cannot shrug the file off, and the error
        list is what names which file broke instead of leaving a bare off-by-one.
        Asserting the errors stay empty therefore also pins that nothing in the
        real suite relies on the synthetic case to reach the expected number.
        """
        with tempfile.TemporaryDirectory() as scratch:
            tests = Path(scratch) / "tests"
            tests.mkdir()
            (tests / "test_ok.py").write_text(
                "import unittest\n\n"
                "class Ok(unittest.TestCase):\n"
                "    def test_one(self):\n        pass\n",
                encoding="utf-8")
            (tests / "test_broken.py").write_text(
                "raise ImportError('this file cannot be imported')\n",
                encoding="utf-8")
            loader = unittest.TestLoader()
            discovered = loader.discover(str(tests))
            errors = list(loader.errors)
            # One real case plus one synthetic failure, never zero of either.
            self.assertEqual(discovered.countTestCases(), 2)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("test_broken", str(errors[0]))


if __name__ == "__main__":
    unittest.main()
