#!/usr/bin/env python3
"""
test_check_intent_recorded.py — self-verify check-intent-recorded.py.

  - KNOWN-BAD: wave4-final.diff + cleanup commit msg + intent-empty-dir.
               Prod LOC ≥ threshold AND no intent file matches subject.
               Expect non-zero exit with `INTENT-MISSING` in stdout.

  - KNOWN-BAD-2: wave4-final.diff + cleanup commit msg + intent-missing-dir.
                 Intent file matches subject but is missing
                 `## Anti-claims` section. Expect non-zero exit with
                 `INTENT-INVALID` in stdout.

  - KNOWN-GOOD: wave4-final.diff + cleanup commit msg + intent-good-dir.
                Intent file matches subject and has all required sections.
                Expect exit 0.

Exit 0 if ALL THREE expectations met; exit 1 otherwise.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-intent-recorded.py"
_FIXTURES = _REPO_ROOT / "scripts" / "_fixtures" / "m1"
_DIFF = _FIXTURES / "wave4-final.diff"
_COMMIT = _FIXTURES / "commit-msg-cleanup-good.txt"


def _run(intent_dir: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        [
            "python3", str(_SCRIPT),
            "--diff", str(_DIFF),
            "--commit-msg", str(_COMMIT),
            "--intent-dir", str(intent_dir),
            "--threshold-loc", "1",
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

    # KNOWN-BAD: empty intent dir → INTENT-MISSING.
    empty_dir = _FIXTURES / "intent-empty-dir"
    rc, out, _ = _run(empty_dir)
    if rc == 0:
        failures.append(
            f"KNOWN-BAD (empty dir): expected non-zero exit, got 0.\n"
            f"  stdout: {out!r}"
        )
    if "INTENT-MISSING" not in out:
        failures.append(
            f"KNOWN-BAD (empty dir): expected `INTENT-MISSING` in stdout.\n"
            f"  stdout: {out!r}"
        )

    # KNOWN-BAD-2: matching intent but missing Anti-claims → INTENT-INVALID.
    missing_dir = _FIXTURES / "intent-missing-dir"
    rc2, out2, _ = _run(missing_dir)
    if rc2 == 0:
        failures.append(
            f"KNOWN-BAD-2 (missing-section dir): expected non-zero exit, "
            f"got 0.\n  stdout: {out2!r}"
        )
    if "INTENT-INVALID" not in out2:
        failures.append(
            f"KNOWN-BAD-2 (missing-section dir): expected `INTENT-INVALID` "
            f"in stdout.\n  stdout: {out2!r}"
        )
    if "Anti-claims" not in out2:
        failures.append(
            f"KNOWN-BAD-2 (missing-section dir): expected `Anti-claims` "
            f"named in reason.\n  stdout: {out2!r}"
        )

    # KNOWN-GOOD: full valid intent file.
    good_dir = _FIXTURES / "intent-good-dir"
    rc3, out3, err3 = _run(good_dir)
    if rc3 != 0:
        failures.append(
            f"KNOWN-GOOD (good intent dir): expected exit 0, got {rc3}.\n"
            f"  stdout: {out3!r}\n  stderr: {err3!r}"
        )

    # KNOWN-BAD-3 (bug-investigation gate): a `type: bugfix` intent missing the
    # `## Verification` section → INTENT-INVALID naming Verification.
    bugfix_missing_dir = _FIXTURES / "intent-bugfix-missing-dir"
    rc4, out4, _ = _run(bugfix_missing_dir)
    if rc4 == 0:
        failures.append(
            f"KNOWN-BAD-3 (bugfix missing Verification): expected non-zero "
            f"exit, got 0.\n  stdout: {out4!r}"
        )
    if "INTENT-INVALID" not in out4 or "Verification" not in out4:
        failures.append(
            f"KNOWN-BAD-3 (bugfix missing Verification): expected "
            f"`INTENT-INVALID` naming `Verification`.\n  stdout: {out4!r}"
        )

    # KNOWN-GOOD-2 (bug-investigation gate): a complete `type: bugfix` intent
    # with Reproduction + Root cause + Verification → exit 0.
    bugfix_good_dir = _FIXTURES / "intent-bugfix-good-dir"
    rc5, out5, err5 = _run(bugfix_good_dir)
    if rc5 != 0:
        failures.append(
            f"KNOWN-GOOD-2 (complete bugfix intent): expected exit 0, got "
            f"{rc5}.\n  stdout: {out5!r}\n  stderr: {err5!r}"
        )

    if failures:
        print("FAIL: test_check_intent_recorded.py:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: test_check_intent_recorded.py "
          "(KNOWN-BAD MISSING + KNOWN-BAD INVALID + KNOWN-GOOD all matched)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
