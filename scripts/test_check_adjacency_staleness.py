#!/usr/bin/env python3
"""
test_check_adjacency_staleness.py — self-verify check-adjacency-staleness.py.

Adjacency-staleness is warn-only (always exits 0); the contract is to
detect the right number of stale comment references for a given diff.

  - KNOWN-BAD: scripts/_fixtures/m1/adjacency-rename.diff against the
               synthetic codebase under scripts/_fixtures/m1/adjacency-codebase/.
               Removes `SignInModalHostingController`; the codebase fixture
               has 4 stale comment refs.
               Expect 4 ADJ-STALE warnings in stdout.

  - KNOWN-GOOD: scripts/_fixtures/m1/wave4-final.diff against the same
                synthetic codebase. No removed declarations → no warnings.
                Expect zero ADJ-STALE lines in stdout.

Exit 0 if BOTH expectations met; exit 1 otherwise.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-adjacency-staleness.py"
_FIXTURES = _REPO_ROOT / "scripts" / "_fixtures" / "m1"
_FIXTURE_CODEBASE = _FIXTURES / "adjacency-codebase"


def _run(diff_path: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        [
            "python3", str(_SCRIPT),
            "--diff", str(diff_path),
            "--root", str(_FIXTURE_CODEBASE),
            "--quiet",
        ],
        capture_output=True,
        text=True,
        cwd=str(_REPO_ROOT),
        timeout=30,
    )
    return (result.returncode, result.stdout, result.stderr)


def main() -> int:
    failures: list[str] = []

    # KNOWN-BAD: rename diff with 4 stale doc references.
    bad_diff = _FIXTURES / "adjacency-rename.diff"
    bad_rc, bad_out, _ = _run(bad_diff)
    if bad_rc != 0:
        failures.append(
            f"KNOWN-BAD: expected exit 0 (warn-only) on {bad_diff.name}, "
            f"got {bad_rc}."
        )
    adj_lines = [ln for ln in bad_out.splitlines() if ln.startswith("ADJ-STALE:")]
    if len(adj_lines) != 4:
        failures.append(
            f"KNOWN-BAD: expected 4 ADJ-STALE lines on {bad_diff.name}, "
            f"got {len(adj_lines)}.\n"
            f"  stdout:\n{bad_out}"
        )
    if not all("SignInModalHostingController" in ln for ln in adj_lines):
        failures.append(
            f"KNOWN-BAD: expected every ADJ-STALE line to mention "
            f"`SignInModalHostingController`.\n"
            f"  stdout:\n{bad_out}"
        )

    # KNOWN-GOOD: wave4-final removes nothing (only edits/visibility).
    good_diff = _FIXTURES / "wave4-final.diff"
    good_rc, good_out, _ = _run(good_diff)
    if good_rc != 0:
        failures.append(
            f"KNOWN-GOOD: expected exit 0 on {good_diff.name}, got {good_rc}."
        )
    good_warnings = [ln for ln in good_out.splitlines()
                     if ln.startswith("ADJ-STALE:")]
    if good_warnings:
        failures.append(
            f"KNOWN-GOOD: expected 0 ADJ-STALE warnings on {good_diff.name}, "
            f"got {len(good_warnings)}.\n"
            f"  stdout:\n{good_out}"
        )

    if failures:
        print("FAIL: test_check_adjacency_staleness.py:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: test_check_adjacency_staleness.py "
          "(KNOWN-BAD: 4 ADJ-STALE warnings, KNOWN-GOOD: 0 warnings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
