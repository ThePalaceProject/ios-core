#!/usr/bin/env python3
"""
test_check_singleton_leaks.py — self-verify check-singleton-leaks.py.

KNOWN-BAD: 3 unmarked sites → expect 3 SINGLETON-LEAK lines + exit 1.
KNOWN-GOOD: all marked or mocked → expect 0 lines + exit 0.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-singleton-leaks.py"
_FIXTURES = _REPO_ROOT / "scripts" / "_fixtures" / "w2" / "check-singleton-leaks"


def _run(fixture: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        ["python3", str(_SCRIPT), "--file", str(fixture), "--quiet"],
        capture_output=True,
        text=True,
        cwd=str(_REPO_ROOT),
        timeout=30,
    )
    return (result.returncode, result.stdout, result.stderr)


def main() -> int:
    failures: list[str] = []

    bad = _FIXTURES / "known-bad.swift"
    bad_rc, bad_out, bad_err = _run(bad)
    if bad_rc != 1:
        failures.append(
            f"KNOWN-BAD: expected exit 1 on {bad.name}, got {bad_rc}.\n"
            f"  stderr:\n{bad_err}"
        )
    bad_findings = [ln for ln in bad_err.splitlines()
                    if "SINGLETON-LEAK" in ln]
    if len(bad_findings) != 3:
        failures.append(
            f"KNOWN-BAD: expected 3 SINGLETON-LEAK findings on {bad.name}, "
            f"got {len(bad_findings)}.\n"
            f"  stderr:\n{bad_err}"
        )

    good = _FIXTURES / "known-good.swift"
    good_rc, good_out, good_err = _run(good)
    if good_rc != 0:
        failures.append(
            f"KNOWN-GOOD: expected exit 0 on {good.name}, got {good_rc}.\n"
            f"  stderr:\n{good_err}"
        )
    good_findings = [ln for ln in good_err.splitlines()
                     if "SINGLETON-LEAK" in ln]
    if good_findings:
        failures.append(
            f"KNOWN-GOOD: expected 0 SINGLETON-LEAK findings on {good.name}, "
            f"got {len(good_findings)}.\n"
            f"  stderr:\n{good_err}"
        )

    if failures:
        print("FAIL: test_check_singleton_leaks.py:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: test_check_singleton_leaks.py "
          "(KNOWN-BAD: 3 leaks, KNOWN-GOOD: 0 leaks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
