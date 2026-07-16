#!/usr/bin/env python3
"""
Tests for check-pre-ga-crash-triage.py.

The anchor scenario is the real 3.2.0 miss: the saveSync-deadlock signature
(8afb1c66), FATAL, firstSeenVersion 3.2.0, 8 RC-build events — un-triaged, so
the gate must BLOCK GA; triaged, it must pass.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "check-pre-ga-crash-triage.py"

# The real regression that motivated the gate.
SAVESYNC = {
    "id": "8afb1c66ce5dde59b8774424240af778",
    "title": "BookRegistrySync.saveSync reentrancy deadlock",
    "errorType": "FATAL",
    "firstSeenVersion": "3.2.0",
    "eventsCount": 8,
    "impactedUsersCount": 6,
}
# A crash inherited from an older version — NOT this release's fault to block on.
INHERITED = {
    "id": "deadbeef0001",
    "title": "old TPPNetwork crash",
    "errorType": "FATAL",
    "firstSeenVersion": "3.1.0",
    "eventsCount": 40,
    "impactedUsersCount": 12,
}
# A brand-new NON_FATAL — the gate only blocks on FATAL (and ANR opt-in).
NEW_NONFATAL = {
    "id": "cafe0002",
    "title": "handled exception",
    "errorType": "NON_FATAL",
    "firstSeenVersion": "3.2.0",
    "eventsCount": 100,
    "impactedUsersCount": 30,
}


def _write(tmp: Path, name: str, obj) -> Path:
    p = tmp / name
    p.write_text(json.dumps(obj))
    return p


def _run(tmp: Path, issues_path: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT),
         "--release-version", "3.2.0", "--issues-json", str(issues_path), *extra],
        cwd=tmp, capture_output=True, text=True,
    )


def test_new_fatal_untriaged_blocks(tmp_path: Path):
    issues = _write(tmp_path, "i.json", [SAVESYNC, INHERITED])
    res = _run(tmp_path, issues)
    assert res.returncode == 1, res.stderr
    assert "BLOCK" in res.stderr
    assert "8afb1c66" in res.stderr


def test_triaged_signature_passes(tmp_path: Path):
    issues = _write(tmp_path, "i.json", [SAVESYNC])
    ledger = tmp_path / "triage.txt"
    ledger.write_text("8afb1c66ce5dde59b8774424240af778 PP-4819 fixed in 3.2.1 hotfix\n")
    res = _run(tmp_path, issues, "--triage-file", str(ledger))
    assert res.returncode == 0, res.stderr
    assert "triaged" in res.stderr.lower()


def test_triage_by_id_prefix(tmp_path: Path):
    issues = _write(tmp_path, "i.json", [SAVESYNC])
    ledger = tmp_path / "triage.txt"
    ledger.write_text("8afb1c66 known — riding 3.3.0\n")  # prefix match
    res = _run(tmp_path, issues, "--triage-file", str(ledger))
    assert res.returncode == 0, res.stderr


def test_inherited_crash_not_blocking(tmp_path: Path):
    # Only the inherited (3.1.0) FATAL present — not new in 3.2.0.
    issues = _write(tmp_path, "i.json", [INHERITED])
    res = _run(tmp_path, issues)
    assert res.returncode == 0, res.stderr


def test_new_nonfatal_ignored(tmp_path: Path):
    issues = _write(tmp_path, "i.json", [NEW_NONFATAL])
    res = _run(tmp_path, issues)
    assert res.returncode == 0, res.stderr


def test_min_events_threshold(tmp_path: Path):
    low = dict(SAVESYNC, eventsCount=2)
    issues = _write(tmp_path, "i.json", [low])
    res = _run(tmp_path, issues, "--min-events", "5")
    assert res.returncode == 0, res.stderr  # below threshold -> ignored
    res2 = _run(tmp_path, issues, "--min-events", "1")
    assert res2.returncode == 1, res2.stderr  # at/above -> blocks


def test_anr_opt_in(tmp_path: Path):
    anr = {"id": "anr01", "title": "main-thread hang", "errorType": "ANR",
           "firstSeenVersion": "3.2.0", "eventsCount": 10, "impactedUsersCount": 4}
    issues = _write(tmp_path, "i.json", [anr])
    assert _run(tmp_path, issues).returncode == 0                       # off by default
    assert _run(tmp_path, issues, "--include-anr").returncode == 1      # opt-in blocks


def test_issues_wrapper_shape(tmp_path: Path):
    issues = _write(tmp_path, "i.json", {"issues": [SAVESYNC]})
    res = _run(tmp_path, issues)
    assert res.returncode == 1, res.stderr


def test_clean_board_passes(tmp_path: Path):
    issues = _write(tmp_path, "i.json", [INHERITED, NEW_NONFATAL])
    res = _run(tmp_path, issues)
    assert res.returncode == 0, res.stderr


def test_bad_json_errors(tmp_path: Path):
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    res = _run(tmp_path, bad)
    assert res.returncode == 2, res.stderr


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
