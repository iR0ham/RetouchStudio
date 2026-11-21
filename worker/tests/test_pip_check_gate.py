"""`pip check` must be able to fail, not only able to say "nothing found".

The payload job's previous step captured stdout with `|| true`, so a pip that
crashed (traceback on stderr, empty stdout) left the filter with nothing to
report and the step passed. These tests seed that crash, an unexpected
requirement, and the documented mflux gap at the judge level; the same judge
runs in CI on the real environment, so the seedings here are the failure
demonstration for a defect the CI environment cannot easily reproduce.
"""
import contextlib
import importlib.util
import io
import unittest
from pathlib import Path
from types import SimpleNamespace

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

    def test_the_measured_cases_drive_the_exit_code(self):
        """D1–D5 as measured on `80b23eea7`, through `main` itself.

        The old pipeline passed D1, D4 and D5. Each row states the expected
        verdict and the exit code the step would take.
        """
        traceback = ("Traceback (most recent call last):\n"
                     "  File \"pip/_internal/cli/main.py\", line 1\n"
                     "ModuleNotFoundError: No module named 'pip'")
        cases = {
            # label: (status, stdout, stderr, expected exit, why)
            "D1 crash, traceback on stderr, empty stdout": (
                1, "", traceback, 1, "a crashed check is not a pass"),
            "D2 unexpected requirement": (
                1, "torch 2.9.0 requires sympy, which is not installed.",
                "", 1, "the lock is incomplete"),
            "D3 documented mflux gap": (1, GAP, "", 0, "the one exception"),
            "D4 clean line plus a traceback": (
                0, CLEAN, traceback, 1, "the check did not complete"),
            "D5 completely silent, status 0": (
                0, "", "", 1, "no verdict at all"),
            "D5b completely silent, status 1": (
                1, "", "", 1, "no verdict at all"),
        }
        for label, (status, stdout, stderr, expected, why) in cases.items():
            with self.subTest(case=label):
                proc = SimpleNamespace(returncode=status, stdout=stdout,
                                      stderr=stderr)
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), \
                        contextlib.redirect_stderr(err):
                    code = gate.main(runner=lambda proc=proc: proc)
                self.assertEqual(code, expected, why)
                if expected:
                    self.assertIn("PIP CHECK GATE: FAIL", err.getvalue())
                else:
                    self.assertIn("PIP CHECK GATE: PASS", out.getvalue())


if __name__ == "__main__":
    unittest.main()
