#!/usr/bin/env python3
"""
test_regression_crash_harvest.py — pytest harness for
scripts/regression_crash_harvest.py (the C-ipad-on-mac WS-4 crash detector).

Asserts the deterministic core:
  - classify_crash_text recognises the WS-4 recursive_mutex signature, the
    Crashlytics 9a91840677 id, and the abort+Adobe-frame upgrade path;
  - clean / unrelated crashes are NOT misclassified as WS-4;
  - harvest() matches only our process and only reports newer than `since`;
  - a WS-4 hit emits a finding into the cell's own shard with the pinned
    schema (classification=device-divergence, blocker), and PASS emits none.

Fixtures are synthesised in tmp_path — no dependency on the host's real
DiagnosticReports.
"""
from __future__ import annotations

import csv
import importlib.util
import json
import time
from pathlib import Path

import pytest

_SCRIPTS = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "regression_crash_harvest", _SCRIPTS / "regression_crash_harvest.py"
)
harvest_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(harvest_mod)


def _ips(app="Palace", exc="EXC_CRASH", body=""):
    """Build a minimal modern .ips text: JSON header line + payload."""
    header = json.dumps({"app_name": app, "procName": app})
    payload = json.dumps({"exceptionType": exc, "body": body})
    return header + "\n" + payload


WS4_RECURSIVE_MUTEX = _ips(
    body="terminating with uncaught exception ... recursive_mutex lock failed: "
         "Invalid argument in dp::DPCriticalSection")
WS4_CRASHLYTICS_ID = _ips(body="Crashlytics issue 9a91840677 fatal at exit")
ABORT_ADOBE_FRAME = _ips(
    exc="EXC_CRASH (SIGABRT)",
    body="Thread 0 Crashed:\n0 librmsdk  dp::SomeAdeptCall()\n1 libc abort")
PALACE_NON_WS4 = _ips(
    exc="EXC_BAD_ACCESS",
    body="Thread 0 Crashed:\n0 Palace  Swift.Optional.unsafelyUnwrapped")
OTHER_PROCESS = _ips(app="Mail", body="recursive_mutex lock failed")  # not ours


# --- pure classifier ---------------------------------------------------------

def test_classify_recursive_mutex_is_ws4():
    r = harvest_mod.classify_crash_text(WS4_RECURSIVE_MUTEX)
    assert r["is_ws4"] is True
    assert any("recursive_mutex" in s for s in r["matched_signatures"])


def test_classify_crashlytics_id_is_ws4():
    assert harvest_mod.classify_crash_text(WS4_CRASHLYTICS_ID)["is_ws4"] is True


def test_classify_abort_plus_adobe_frame_upgrades_to_ws4():
    r = harvest_mod.classify_crash_text(ABORT_ADOBE_FRAME)
    assert r["is_ws4"] is True
    assert r["matched_signatures"] == ["abort+adobe-frame"]


def test_classify_palace_non_ws4_is_not_ws4():
    r = harvest_mod.classify_crash_text(PALACE_NON_WS4)
    assert r["is_ws4"] is False
    assert r["matched_signatures"] == []


def test_classify_plain_abort_without_adobe_is_not_ws4():
    plain = _ips(exc="EXC_CRASH (SIGABRT)", body="0 Foundation -[NSArray objectAtIndex]")
    assert harvest_mod.classify_crash_text(plain)["is_ws4"] is False


# --- harvest scoping ---------------------------------------------------------

def _write(dirpath: Path, name: str, text: str, mtime: float | None = None):
    p = dirpath / name
    p.write_text(text)
    if mtime is not None:
        import os
        os.utime(p, (mtime, mtime))
    return p


def test_harvest_matches_only_our_process(tmp_path):
    rd = tmp_path / "reports"; rd.mkdir()
    _write(rd, "a.ips", WS4_RECURSIVE_MUTEX)
    _write(rd, "b.ips", OTHER_PROCESS)
    got = harvest_mod.harvest("Palace", since_epoch=0, reports_dir=str(rd))
    procs = {c["process"] for c in got}
    assert "Palace" in procs and "Mail" not in procs
    assert len(got) == 1 and got[0]["is_ws4"] is True


def test_harvest_ignores_reports_older_than_since(tmp_path):
    rd = tmp_path / "reports"; rd.mkdir()
    now = time.time()
    _write(rd, "old.ips", WS4_RECURSIVE_MUTEX, mtime=now - 600)
    _write(rd, "new.ips", WS4_RECURSIVE_MUTEX, mtime=now)
    got = harvest_mod.harvest("Palace", since_epoch=now - 60, reports_dir=str(rd))
    assert len(got) == 1
    assert Path(got[0]["path"]).name == "new.ips"


def test_harvest_missing_dir_returns_empty(tmp_path):
    assert harvest_mod.harvest("Palace", 0, str(tmp_path / "nope")) == []


# --- findings emission (own shard, pinned schema) ----------------------------

_EXPECTED_COLUMNS = [
    "id", "area", "device_cell", "severity", "classification", "verified",
    "evidence_paths", "screenshot_pair", "first_seen_commit", "dedup_cluster",
    "disposition",
]


def test_ws4_hit_emits_finding_into_own_shard(tmp_path):
    rd = tmp_path / "reports"; rd.mkdir()
    _write(rd, "crash.ips", WS4_RECURSIVE_MUTEX)
    run_dir = tmp_path / "run"
    crashes = harvest_mod.harvest("Palace", 0, str(rd))
    shard = harvest_mod._emit_findings(
        str(run_dir), "C-ipad-on-mac", "audiobook-drm-exit", crashes,
        first_seen_commit="deadbee", scan_log=str(tmp_path / "scan.log"),
    )
    assert shard is not None
    sp = Path(shard)
    assert sp.name == "C-ipad-on-mac__audiobook-drm-exit.csv"  # own shard naming
    rows = list(csv.DictReader(sp.open()))
    assert len(rows) == 1
    row = rows[0]
    assert list(row.keys()) == _EXPECTED_COLUMNS          # pinned schema/order
    assert row["classification"] == "device-divergence"
    assert row["severity"] == "blocker"
    assert row["verified"] == "false"
    assert row["dedup_cluster"] == "ws4-adobe-recursive-mutex"
    assert "crash.ips" in row["evidence_paths"]
    assert row["first_seen_commit"] == "deadbee"


def test_pass_emits_no_finding(tmp_path):
    rd = tmp_path / "reports"; rd.mkdir()
    _write(rd, "ok.ips", PALACE_NON_WS4)  # matches process, not WS-4
    run_dir = tmp_path / "run"
    crashes = harvest_mod.harvest("Palace", 0, str(rd))
    shard = harvest_mod._emit_findings(
        str(run_dir), "C-ipad-on-mac", "audiobook-drm-exit", crashes,
        first_seen_commit="", scan_log=None,
    )
    assert shard is None
    assert not (run_dir / "findings").exists() or \
        not list((run_dir / "findings").glob("*.csv"))


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
