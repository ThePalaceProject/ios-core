#!/usr/bin/env python3
"""
test_check_blast_radius.py — self-verify scripts/check-blast-radius.py.

Runs the script via subprocess against:
  - KNOWN-BAD: scripts/_fixtures/m1/wave4-pre-cleanup.diff
               (contains `+ public private(set) var authenticateCallCount`).
               Expect non-zero exit (BR-3 high finding).
  - KNOWN-GOOD: scripts/_fixtures/m1/wave4-final.diff
               (post-cleanup; `internal private(set)`).
               Expect exit 0.

Exit 0 if BOTH expectations met; exit 1 otherwise.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-blast-radius.py"
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

    # KNOWN-BAD: wave4-pre-cleanup must FAIL (non-zero exit + BR-3 line).
    bad_diff = _FIXTURES / "wave4-pre-cleanup.diff"
    bad_rc, bad_out, bad_err = _run(bad_diff)
    if bad_rc == 0:
        failures.append(
            f"KNOWN-BAD: expected non-zero exit on {bad_diff.name}, got 0.\n"
            f"  stdout: {bad_out!r}"
        )
    if "BR-3" not in bad_out:
        failures.append(
            f"KNOWN-BAD: expected `BR-3` finding in stdout on {bad_diff.name}.\n"
            f"  stdout: {bad_out!r}"
        )
    if "authenticateCallCount" not in bad_out:
        failures.append(
            f"KNOWN-BAD: expected `authenticateCallCount` mentioned in "
            f"finding on {bad_diff.name}.\n  stdout: {bad_out!r}"
        )

    # KNOWN-GOOD: wave4-final must PASS (exit 0, no high findings).
    good_diff = _FIXTURES / "wave4-final.diff"
    good_rc, good_out, good_err = _run(good_diff)
    if good_rc != 0:
        failures.append(
            f"KNOWN-GOOD: expected exit 0 on {good_diff.name}, got {good_rc}.\n"
            f"  stdout: {good_out!r}\n  stderr: {good_err!r}"
        )
    if "BR-3" in good_out:
        failures.append(
            f"KNOWN-GOOD: did not expect `BR-3` finding on {good_diff.name}.\n"
            f"  stdout: {good_out!r}"
        )

    if failures:
        print("FAIL: test_check_blast_radius.py:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: test_check_blast_radius.py (KNOWN-BAD blocked, KNOWN-GOOD passed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
