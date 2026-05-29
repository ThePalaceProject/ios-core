#!/usr/bin/env python3
"""
test_check_test_tautology.py — self-verify check-test-tautology.py.

Uses a synthetic codebase under
  scripts/_fixtures/w2/check-test-tautology/codebase/
that declares AccountsManager with NON-optional `accounts()` and
`currentLibraryUUID()`, plus Optional `lookupCatalog()` / `explicitOptional()`.

KNOWN-BAD: 2 XCTAssertNotNil on non-optional returns → expect 2 + exit 1.
KNOWN-GOOD: Optional + marked + bare + unknown + behavioral → expect 0 + exit 0.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-test-tautology.py"
_FIXTURES = _REPO_ROOT / "scripts" / "_fixtures" / "w2" / "check-test-tautology"
_FIXTURE_CODEBASE = _FIXTURES / "codebase"


def _run(fixture: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        [
            "python3", str(_SCRIPT),
            "--file", str(fixture),
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

    bad = _FIXTURES / "known-bad.swift"
    bad_rc, _, bad_err = _run(bad)
    if bad_rc != 1:
        failures.append(
            f"KNOWN-BAD: expected exit 1 on {bad.name}, got {bad_rc}.\n"
            f"  stderr:\n{bad_err}"
        )
    bad_findings = [ln for ln in bad_err.splitlines()
                    if "TEST-TAUTOLOGY" in ln]
    if len(bad_findings) != 2:
        failures.append(
            f"KNOWN-BAD: expected 2 TEST-TAUTOLOGY findings on {bad.name}, "
            f"got {len(bad_findings)}.\n"
            f"  stderr:\n{bad_err}"
        )

    good = _FIXTURES / "known-good.swift"
    good_rc, _, good_err = _run(good)
    if good_rc != 0:
        failures.append(
            f"KNOWN-GOOD: expected exit 0 on {good.name}, got {good_rc}.\n"
            f"  stderr:\n{good_err}"
        )
    good_findings = [ln for ln in good_err.splitlines()
                     if "TEST-TAUTOLOGY" in ln]
    if good_findings:
        failures.append(
            f"KNOWN-GOOD: expected 0 TEST-TAUTOLOGY findings on {good.name}, "
            f"got {len(good_findings)}.\n"
            f"  stderr:\n{good_err}"
        )

    if failures:
        print("FAIL: test_check_test_tautology.py:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: test_check_test_tautology.py "
          "(KNOWN-BAD: 2 tautologies, KNOWN-GOOD: 0)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
