#!/usr/bin/env python3
"""
test_check_superpartner_spectrum.py — self-verify check-superpartner-spectrum.py.

check-superpartner-spectrum.py scans a diff for new production code (functions,
enum cases, state changes) that ships without a matching test, and at the
default `--severity-floor high` blocks untested new code on a critical path.

  - KNOWN-BAD: scripts/_fixtures/m1/superpartner-untested-bad.diff
               Adds `computeRenewalEligibility` to the critical-path file
               Palace/MyBooks/BorrowOperation.swift with no test.
               Expect non-zero exit + an SP-1 high finding mentioning the func.

  - KNOWN-GOOD: scripts/_fixtures/m1/superpartner-tested-good.diff
               Adds the same func AND a paired test that calls it.
               Expect exit 0, no SP-1 finding.

Exit 0 if BOTH expectations met; exit 1 otherwise.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-superpartner-spectrum.py"
_FIXTURES = _REPO_ROOT / "scripts" / "_fixtures" / "m1"


def _run(diff_path: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        ["python3", str(_SCRIPT), "--diff", str(diff_path), "--quiet"],
        capture_output=True,
        text=True,
        cwd=str(_REPO_ROOT),
        timeout=30,
    )
    return (result.returncode, result.stdout, result.stderr)


def main() -> int:
    failures: list[str] = []

    # KNOWN-BAD: untested critical-path func must FAIL at the default floor.
    bad = _FIXTURES / "superpartner-untested-bad.diff"
    bad_rc, bad_out, _ = _run(bad)
    if bad_rc == 0:
        failures.append(
            f"KNOWN-BAD: expected non-zero exit on {bad.name}, got 0.\n"
            f"  stdout: {bad_out!r}"
        )
    if "SP-1" not in bad_out:
        failures.append(
            f"KNOWN-BAD: expected an `SP-1` (new func) finding on {bad.name}.\n"
            f"  stdout: {bad_out!r}"
        )
    if "high" not in bad_out:
        failures.append(
            f"KNOWN-BAD: expected `high` severity (critical-path file) on "
            f"{bad.name}.\n  stdout: {bad_out!r}"
        )
    if "computeRenewalEligibility" not in bad_out:
        failures.append(
            f"KNOWN-BAD: expected the finding to mention "
            f"`computeRenewalEligibility` on {bad.name}.\n  stdout: {bad_out!r}"
        )

    # KNOWN-GOOD: same func with a paired test must PASS (exit 0, no SP-1).
    good = _FIXTURES / "superpartner-tested-good.diff"
    good_rc, good_out, good_err = _run(good)
    if good_rc != 0:
        failures.append(
            f"KNOWN-GOOD: expected exit 0 on {good.name}, got {good_rc}.\n"
            f"  stdout: {good_out!r}\n  stderr: {good_err!r}"
        )
    if "SP-1" in good_out:
        failures.append(
            f"KNOWN-GOOD: did not expect an `SP-1` finding on {good.name} "
            f"(the func has a paired test).\n  stdout: {good_out!r}"
        )

    if failures:
        print("FAIL: test_check_superpartner_spectrum.py:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: test_check_superpartner_spectrum.py "
          "(KNOWN-BAD: untested critical-path func blocked, "
          "KNOWN-GOOD: paired test passed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
