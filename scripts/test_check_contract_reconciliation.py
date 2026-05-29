#!/usr/bin/env python3
"""
test_check_contract_reconciliation.py — self-verify
check-contract-reconciliation.py.

  - KNOWN-BAD: scaffold-bad commit body vs wave4-final.diff.
               Claims "removes SignInModalHostingController" and
               "extracts TPPReauthenticatorBlastRadiusReviewer into a
               separate file" but the diff contains neither.
               Expect non-zero exit with `UNSUPPORTED` REM claim.

  - KNOWN-GOOD: cleanup-good commit body vs wave4-final.diff.
                Claims "renames SignInModalHostingController to
                SignInModalDismissalHosting" — the diff shows the
                rename via `-` + `+` lines. Expect exit 0.

Exit 0 if BOTH expectations met; exit 1 otherwise.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-contract-reconciliation.py"
_FIXTURES = _REPO_ROOT / "scripts" / "_fixtures" / "m1"
_DIFF = _FIXTURES / "wave4-final.diff"


def _run(commit_msg: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        [
            "python3", str(_SCRIPT),
            "--commit-msg", str(commit_msg),
            "--diff", str(_DIFF),
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

    # KNOWN-BAD: scaffold body's "removes HostingController" claim is unsupported.
    bad_msg = _FIXTURES / "commit-msg-scaffold-bad.txt"
    bad_rc, bad_out, _ = _run(bad_msg)
    if bad_rc == 0:
        failures.append(
            f"KNOWN-BAD: expected non-zero exit on {bad_msg.name}, got 0.\n"
            f"  stdout: {bad_out!r}"
        )
    if "UNSUPPORTED" not in bad_out:
        failures.append(
            f"KNOWN-BAD: expected `UNSUPPORTED` in stdout on {bad_msg.name}.\n"
            f"  stdout: {bad_out!r}"
        )
    if "SignInModalHostingController" not in bad_out:
        failures.append(
            f"KNOWN-BAD: expected the unsupported claim to cite "
            f"`SignInModalHostingController`.\n  stdout: {bad_out!r}"
        )

    # KNOWN-GOOD: cleanup body's rename claim is supported by the diff.
    good_msg = _FIXTURES / "commit-msg-cleanup-good.txt"
    good_rc, good_out, good_err = _run(good_msg)
    if good_rc != 0:
        failures.append(
            f"KNOWN-GOOD: expected exit 0 on {good_msg.name}, got {good_rc}.\n"
            f"  stdout: {good_out!r}\n  stderr: {good_err!r}"
        )
    if "UNSUPPORTED" in good_out:
        failures.append(
            f"KNOWN-GOOD: did not expect any `UNSUPPORTED` lines.\n"
            f"  stdout: {good_out!r}"
        )

    if failures:
        print("FAIL: test_check_contract_reconciliation.py:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: test_check_contract_reconciliation.py "
          "(KNOWN-BAD unsupported claim caught, KNOWN-GOOD all claims reconciled)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
