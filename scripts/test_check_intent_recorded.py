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
                Intent file covers the diff and has all required sections.
                Expect exit 0.

  - REWORD-IMMUNE / NO-SUBJECT / REWORD-CANNOT-RESCUE / SCOPE-INCOMPLETE
                (PP-5024): the verdict follows the intent file's
                `## Files in scope` against the files the diff changes, not
                the wording of the newest commit subject. A correct intent
                stays green under any subject and under no subject at all;
                a name-only match with a scope that misses the diff is red;
                a scope that covers only part of the diff is red and names
                the files it left out.

Exit 0 if EVERY expectation is met; exit 1 otherwise.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-intent-recorded.py"
_FIXTURES = _REPO_ROOT / "scripts" / "_fixtures" / "m1"
_DIFF = _FIXTURES / "wave4-final.diff"
# Same diff, but it also ADDS the intent files — so the intent under test is
# the branch's own. Section validation only speaks for an intent the branch
# wrote; a stranger's malformedness is not this author's finding.
_OWN_DIFF = _FIXTURES / "wave4-final-own-intents.diff"
_COMMIT = _FIXTURES / "commit-msg-cleanup-good.txt"
_UNRELATED_COMMIT = _FIXTURES / "commit-msg-unrelated.txt"
_TWO_FILE_DIFF = _FIXTURES / "scope-two-files.diff"
_OWN_BOTH_DIFF = _FIXTURES / "scope-two-files-own-intents.diff"
_OWN_ONE_DIFF = _FIXTURES / "scope-two-files-own-a.diff"


def _run(intent_dir: Path, commit: Path | None = _COMMIT,
         diff: Path = _DIFF) -> tuple[int, str, str]:
    argv = [
        "python3", str(_SCRIPT),
        "--diff", str(diff),
        "--intent-dir", str(intent_dir),
        "--threshold-loc", "1",
        "--quiet",
    ]
    if commit is not None:
        argv += ["--commit-msg", str(commit)]
    result = subprocess.run(
        argv,
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
    rc2, out2, _ = _run(missing_dir, diff=_OWN_DIFF)
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
    rc4, out4, _ = _run(bugfix_missing_dir, diff=_OWN_DIFF)
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
    rc5, out5, err5 = _run(bugfix_good_dir, diff=_OWN_DIFF)
    if rc5 != 0:
        failures.append(
            f"KNOWN-GOOD-2 (complete bugfix intent): expected exit 0, got "
            f"{rc5}.\n  stdout: {out5!r}\n  stderr: {err5!r}"
        )

    # --- PP-5024: the match is the intent's file scope, not commit wording ---

    # REWORD-IMMUNE: the SAME good intent dir, but the newest commit subject is
    # a narrow "fix review nit" that shares no tokens with the intent name.
    # Under the old subject-token rule this went red; the file scope is
    # unchanged, so it must stay green.
    rc6, out6, err6 = _run(good_dir, commit=_UNRELATED_COMMIT)
    if rc6 != 0:
        failures.append(
            f"REWORD-IMMUNE (good intent, unrelated subject): expected exit "
            f"0, got {rc6}.\n  stdout: {out6!r}\n  stderr: {err6!r}"
        )

    # NO-SUBJECT: with no --commit-msg at all the check still has everything it
    # needs (the diff + the intent's Files in scope), so it must not fail.
    rc7, out7, err7 = _run(good_dir, commit=None)
    if rc7 != 0:
        failures.append(
            f"NO-SUBJECT (good intent, no --commit-msg): expected exit 0, "
            f"got {rc7}.\n  stdout: {out7!r}\n  stderr: {err7!r}"
        )

    # REWORD-CANNOT-RESCUE: an intent whose `name:` token-matches the commit
    # subject exactly, is structurally complete, and describes files the diff
    # never touches. The old rule passed this on the name alone.
    wrong_scope_dir = _FIXTURES / "intent-wrong-scope-dir"
    rc8, out8, _ = _run(wrong_scope_dir)
    if rc8 == 0:
        failures.append(
            f"REWORD-CANNOT-RESCUE (name matches, scope does not): expected "
            f"non-zero exit, got 0.\n  stdout: {out8!r}"
        )
    if "INTENT-MISSING" not in out8:
        failures.append(
            f"REWORD-CANNOT-RESCUE: expected `INTENT-MISSING` in stdout.\n"
            f"  stdout: {out8!r}"
        )

    # TWO-FILE-GOOD: a diff that adds code to two prod files, and an intent
    # listing both. The control for SCOPE-INCOMPLETE below — without it a
    # blanket failure on this diff would look like a working scope check.
    two_file_good = _FIXTURES / "intent-two-file-good-dir"
    rcA, outA, errA = _run(two_file_good, diff=_TWO_FILE_DIFF)
    if rcA != 0:
        failures.append(
            f"TWO-FILE-GOOD (intent lists both changed prod files): expected "
            f"exit 0, got {rcA}.\n  stdout: {outA!r}\n  stderr: {errA!r}"
        )

    # SCOPE-INCOMPLETE: the same diff against an intent that lists only one of
    # the two files. Fails, and names the file it left out.
    partial_dir = _FIXTURES / "intent-partial-scope-dir"
    rc9, out9, _ = _run(partial_dir, diff=_TWO_FILE_DIFF)
    if rc9 == 0:
        failures.append(
            f"SCOPE-INCOMPLETE (covers 2 of 4 prod files): expected non-zero "
            f"exit, got 0.\n  stdout: {out9!r}"
        )
    if "INTENT-SCOPE-INCOMPLETE" not in out9:
        failures.append(
            f"SCOPE-INCOMPLETE: expected `INTENT-SCOPE-INCOMPLETE` in "
            f"stdout.\n  stdout: {out9!r}"
        )
    if "HoldsReducer.swift" not in out9:
        failures.append(
            f"SCOPE-INCOMPLETE: expected the uncovered file to be named.\n"
            f"  stdout: {out9!r}"
        )

    # OWN-UNION: a branch that records TWO intents for two strands of work.
    # Neither covers the diff alone; together they do, and that passes.
    union_dir = _FIXTURES / "intent-own-union-dir"
    rcB, outB, errB = _run(union_dir, diff=_OWN_BOTH_DIFF)
    if rcB != 0:
        failures.append(
            f"OWN-UNION (two branch intents covering one file each): expected "
            f"exit 0, got {rcB}.\n  stdout: {outB!r}\n  stderr: {errB!r}"
        )

    # OWN-NOT-BACKFILLED: the branch records ONE intent covering one of its two
    # files, and an older sibling in the corpus covers the other. The branch's
    # own intent is what gets judged — otherwise "is this work described" is
    # answered by the corpus rather than by the author.
    own_partial_dir = _FIXTURES / "intent-own-partial-dir"
    rcC, outC, _ = _run(own_partial_dir, diff=_OWN_ONE_DIFF)
    if rcC == 0:
        failures.append(
            f"OWN-NOT-BACKFILLED (stranger intent covers the gap): expected "
            f"non-zero exit, got 0.\n  stdout: {outC!r}"
        )
    if "HoldsReducer.swift" not in outC:
        failures.append(
            f"OWN-NOT-BACKFILLED: expected the uncovered file to be named.\n"
            f"  stdout: {outC!r}"
        )

    # INVALID-STRANGER: a pre-frontmatter intent the branch never touched
    # covers the diff. It is NOT selected — reporting INTENT-INVALID here would
    # answer for a file this author did not write, which is what a hotfix
    # forward-port merge into develop would have tripped.
    stranger_dir = _FIXTURES / "intent-invalid-stranger-dir"
    rcD, outD, _ = _run(stranger_dir)
    if rcD == 0:
        failures.append(
            f"INVALID-STRANGER: expected non-zero exit, got 0.\n"
            f"  stdout: {outD!r}")
    if "INTENT-MISSING" not in outD or "INTENT-INVALID" in outD:
        failures.append(
            f"INVALID-STRANGER: expected `INTENT-MISSING`, not "
            f"`INTENT-INVALID`.\n  stdout: {outD!r}")

    # VALID-SIBLING: the same legacy intent, with a well-formed one beside it
    # covering the same file. The valid one is eligible, so this passes — the
    # control proving INVALID-STRANGER fails on validity, not on coverage.
    sibling_dir = _FIXTURES / "intent-valid-beats-invalid-dir"
    rcE, outE, errE = _run(sibling_dir)
    if rcE != 0:
        failures.append(
            f"VALID-SIBLING: expected exit 0, got {rcE}.\n"
            f"  stdout: {outE!r}\n  stderr: {errE!r}")

    if failures:
        print("FAIL: test_check_intent_recorded.py:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: test_check_intent_recorded.py "
          "(MISSING + INVALID + GOOD + bugfix sections + PP-5024 scope "
          "matching all matched)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
