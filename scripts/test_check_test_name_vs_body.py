#!/usr/bin/env python3
"""
test_check_test_name_vs_body.py — self-verify scripts/check-test-name-vs-body.py.

check-test-name-vs-body.py takes Swift test-file path args (not a diff) and
flags XCTest methods whose names embed a multi-step verb + a PascalCase
production-class noun whose body never references that noun (the fake-wiring
shape from .forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md).

  - KNOWN-BAD: scripts/_fixtures/m1/testname-fake-wiring-bad.swift
               `testRefresh_TPPReauthenticatorPath_invokesRetry` embeds
               `TPPReauthenticator` but the body never references it.
               Expect non-zero exit + a finding line mentioning the noun.

  - KNOWN-GOOD: scripts/_fixtures/m1/testname-real-wiring-good.swift
               Same test name, but the body instantiates + drives
               `TPPReauthenticator`. Expect exit 0, no findings.

Exit 0 if BOTH expectations met; exit 1 otherwise.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-test-name-vs-body.py"
_FIXTURES = _REPO_ROOT / "scripts" / "_fixtures" / "m1"


def _run(swift_path: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        ["python3", str(_SCRIPT), str(swift_path)],
        capture_output=True,
        text=True,
        cwd=str(_REPO_ROOT),
        timeout=30,
    )
    return (result.returncode, result.stdout, result.stderr)


def main() -> int:
    failures: list[str] = []

    # KNOWN-BAD: fake-wiring test must FAIL (non-zero exit + noun in finding).
    bad = _FIXTURES / "testname-fake-wiring-bad.swift"
    bad_rc, bad_out, _ = _run(bad)
    if bad_rc == 0:
        failures.append(
            f"KNOWN-BAD: expected non-zero exit on {bad.name}, got 0.\n"
            f"  stdout: {bad_out!r}"
        )
    if "TPPReauthenticator" not in bad_out:
        failures.append(
            f"KNOWN-BAD: expected the finding to mention `TPPReauthenticator` "
            f"on {bad.name}.\n  stdout: {bad_out!r}"
        )
    if "claims" not in bad_out or "no reference" not in bad_out:
        failures.append(
            f"KNOWN-BAD: expected a `claims '<noun>' but body has no reference` "
            f"finding on {bad.name}.\n  stdout: {bad_out!r}"
        )

    # KNOWN-GOOD: real-wiring test must PASS (exit 0, no findings).
    good = _FIXTURES / "testname-real-wiring-good.swift"
    good_rc, good_out, good_err = _run(good)
    if good_rc != 0:
        failures.append(
            f"KNOWN-GOOD: expected exit 0 on {good.name}, got {good_rc}.\n"
            f"  stdout: {good_out!r}\n  stderr: {good_err!r}"
        )
    if "no reference" in good_out:
        failures.append(
            f"KNOWN-GOOD: did not expect a fake-wiring finding on {good.name}.\n"
            f"  stdout: {good_out!r}"
        )

    if failures:
        print("FAIL: test_check_test_name_vs_body.py:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: test_check_test_name_vs_body.py "
          "(KNOWN-BAD flagged the embedded noun, KNOWN-GOOD passed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
