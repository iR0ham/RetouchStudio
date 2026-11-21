"""Turn `pip check` into a gate a crashed check cannot pass.

The payload job installs the full runtime lock with `--no-deps`, so an
unsatisfied requirement the lock forgot would only surface when the package was
used. `pip check` reads every installed distribution's metadata and names each
unsatisfied requirement. Exactly one is expected: mflux declares
opencv-python for its optional ControlNet/OpenPose preprocessing, which the
worker never runs, so the lock deliberately leaves it out.

The step this replaces ran `check=$(python -m pip check || true)` and filtered
the captured stdout. That discarded the exit status and any stderr: a pip that
crashed before printing (a traceback on stderr) produced an empty string, the
filter found nothing unexpected, and the step passed. Here the status, stdout
and stderr are judged together, and the documented exception remains an
exception to the *content* only:

  * status 0 ("No broken requirements found.") is the clean environment;
  * status 1 must carry the documented mflux line and nothing else;
  * any other status, empty output, or a traceback is a failure, whatever
    the content says.

Run it with the interpreter whose environment is being checked:

    worker/.venv/bin/python3 worker/tools/pip_check_gate.py
"""
from __future__ import annotations

import re
import subprocess
import sys

CLEAN = "No broken requirements found."
DOCUMENTED = re.compile(
    r"^mflux \S+ requires opencv-python, which is not installed\.$")
TRACEBACK = "Traceback (most recent call last)"
KNOWN_STATUSES = {0, 1}


def _content_lines(stdout: str, stderr: str) -> list[str]:
    """Lines that carry a verdict, dropping pip's own advisory warnings."""
    lines = []
    for line in (stdout + "\n" + stderr).splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("WARNING:"):
            continue
        lines.append(stripped)
    return lines


def judge(status: int, stdout: str, stderr: str = "") -> list[str]:
    """Return the reasons this `pip check` run cannot be trusted."""
    problems: list[str] = []
    combined = stdout + "\n" + stderr
    if status not in KNOWN_STATUSES:
        problems.append(
            f"pip check exited {status}; only 0 (clean) and 1 (a named "
            f"requirement) are meaningful")
    if TRACEBACK in combined:
        problems.append("pip check raised an exception instead of checking")
    lines = _content_lines(stdout, stderr)
    if not lines:
        problems.append("pip check printed no verdict at all")
        return problems
    unexpected = [line for line in lines
                  if line != CLEAN and not DOCUMENTED.match(line)]
    if unexpected:
        problems.append(
            "requirements the lock does not satisfy: " + " | ".join(unexpected))
    documented = [line for line in lines if DOCUMENTED.match(line)]
    if status == 1 and not documented:
        problems.append(
            "pip check reported a problem but not the documented "
            "mflux -> opencv-python gap")
    if status == 0 and documented:
        problems.append(
            "pip check exited 0 while naming an unsatisfied requirement")
    if status == 0 and CLEAN not in lines:
        problems.append(
            "pip check exited 0 without the clean verdict line")
    return problems


def _invoke():
    return subprocess.run([sys.executable, "-m", "pip", "check"],
                          capture_output=True, text=True)


def main(runner=None) -> int:
    """Judge a `pip check` run; `runner` exists so the seedings can drive it."""
    proc = (runner or _invoke)()
    if proc.stdout:
        print(proc.stdout, end="" if proc.stdout.endswith("\n") else "\n")
    if proc.stderr:
        print(proc.stderr, end="" if proc.stderr.endswith("\n") else "\n",
              file=sys.stderr)
    problems = judge(proc.returncode, proc.stdout, proc.stderr)
    for problem in problems:
        print(f"  ✗ {problem}", file=sys.stderr)
    if problems:
        print(f"PIP CHECK GATE: FAIL ({len(problems)} problem(s))",
              file=sys.stderr)
        return 1
    if any(DOCUMENTED.match(line)
           for line in _content_lines(proc.stdout, proc.stderr)):
        print("PIP CHECK GATE: PASS (only the documented "
              "mflux -> opencv-python gap)")
    else:
        print("PIP CHECK GATE: PASS (no broken requirements)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
