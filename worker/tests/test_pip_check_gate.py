"""`pip check` must be able to fail, not only able to say "nothing found".

The payload job's previous step captured stdout with `|| true`, so a pip that
crashed (traceback on stderr, empty stdout) left the filter with nothing to
report and the step passed. These tests seed that crash, an unexpected
requirement, and the documented mflux gap at the judge level; the same judge
runs in CI on the real environment, so the seedings here are the failure
demonstration for a defect the CI environment cannot easily reproduce.
"""
import importlib.util
import unittest
from pathlib import Path

WORKER = Path(__file__).resolve().parents[1]
TOOL = WORKER / "tools" / "pip_check_gate.py"

_spec = importlib.util.spec_from_file_location("pip_check_gate", TOOL)
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

CLEAN = "No broken requirements found."
GAP = "mflux 0.5.4 requires opencv-python, which is not installed."


class PipCheckGateTest(unittest.TestCase):
    def test_the_two_healthy_outcomes_pass(self):
        self.assertEqual(gate.judge(0, CLEAN, ""), [])
        self.assertEqual(gate.judge(1, GAP, ""), [])
        # pip's own advisory warnings on stderr are not a verdict.
        self.assertEqual(
            gate.judge(1, "WARNING: There was an error checking the latest "
                          "version of pip.\n" + GAP, ""), [])

    def test_a_crashed_check_is_not_a_pass(self):
        """Seeded defect: the old step's empty capture passed this."""
        cases = {
            "no output": (1, "", ""),
            "nonzero and silent": (2, "", ""),
            "traceback on stderr": (
                1, "", "Traceback (most recent call last):\n"
                       "  File \"pip/_internal/cli/main.py\", line 1\n"
                       "ModuleNotFoundError: No module named 'x'"),
        }
        for label, (status, stdout, stderr) in cases.items():
            with self.subTest(case=label):
                self.assertTrue(gate.judge(status, stdout, stderr),
                                "a pip check that did not run must fail")

    def test_content_is_judged_exactly(self):
        unexpected = "torch 2.9.0 requires sympy, which is not installed."
        self.assertTrue(gate.judge(1, GAP + "\n" + unexpected, ""))
        self.assertTrue(gate.judge(1, CLEAN, ""),
                        "exit 1 without the documented gap is a failure")
        self.assertTrue(gate.judge(0, CLEAN + "\n" + GAP, ""),
                        "exit 0 contradicts a named requirement")
        self.assertTrue(gate.judge(0, "", ""))


if __name__ == "__main__":
    unittest.main()
