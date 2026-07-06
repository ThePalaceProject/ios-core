#!/usr/bin/env python3
"""
test_check_intent_recorded_nearmiss.py — R9 near-miss reporting on the
intent-recorded gate.

The 2026-07-05 failure mode: a semantically-obvious subject↔intent pairing
missed the 4-consecutive-token bar and the error listed 80 undifferentiated
candidates without naming the near-miss or the rule. These tests pin the
improved failure message (ranked near-misses + explicit rule + count-only
candidate line) and that exit codes / the match path are unchanged.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-intent-recorded.py"

INTENT = """---
name: segv-mock-race-bookmark-keys
created: 2026-07-05
author: test
---

## Summary
x

## Claims
- x

## Anti-claims
- x

## Files in scope
- x
"""

# A diff adding >10 prod LOC under Palace/.
DIFF = "--- a/Palace/Foo.swift\n+++ b/Palace/Foo.swift\n" + "".join(
    f"+let x{i} = {i}\n" for i in range(15))


def _run(tmp: Path, subject: str) -> tuple[int, str]:
    intent_dir = tmp / "intent"
    intent_dir.mkdir(exist_ok=True)
    (intent_dir / "segv-mock-race-bookmark-keys.md").write_text(INTENT)
    (tmp / "msg.txt").write_text(subject + "\n")
    (tmp / "diff.txt").write_text(DIFF)
    result = subprocess.run(
        ["python3", str(_SCRIPT),
         "--commit-msg", str(tmp / "msg.txt"),
         "--diff", str(tmp / "diff.txt"),
         "--intent-dir", str(intent_dir)],
        capture_output=True, text=True, cwd=str(_REPO_ROOT), timeout=30,
    )
    return result.returncode, result.stdout + result.stderr


def test_near_miss_is_named_with_rule(tmp_path):
    # Shares tokens (mock, race, bookmark, keys) but no 4-consecutive run.
    rc, out = _run(tmp_path, "fix: mock race cleanup for bookmark keys")
    assert rc == 1, out
    assert "closest candidates" in out
    assert "segv-mock-race-bookmark-keys.md" in out.split("Candidates checked")[0]
    assert "Matching rule:" in out


def test_candidate_dump_is_count_only(tmp_path):
    rc, out = _run(tmp_path, "feat: zebra quantum unrelated")
    assert rc == 1, out
    assert "1 file(s)" in out
    # No near-miss block when nothing overlaps.
    assert "closest candidates" not in out


def test_match_path_unchanged(tmp_path):
    rc, out = _run(tmp_path, "fix: segv mock race bookmark keys hardening")
    assert rc == 0, out
    assert "OK: intent file" in out
