#!/usr/bin/env python3
"""
Tests for crashlytics-triage-export.py — the bridge that reshapes the sentinel's
normalized Crashlytics issues into the pre-GA crash-triage gate's schema.

The Firebase fetch is not exercised here (that path is the sentinel's, and hits
the network); these tests pin the pure transform + the end-to-end snapshot path
(raw API payload -> sentinel.load_snapshot -> export shape -> the gate can read it).
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
EXPORT = SCRIPTS / "crashlytics-triage-export.py"
GATE = SCRIPTS / "check-pre-ga-crash-triage.py"


def _load_export_module():
    spec = importlib.util.spec_from_file_location(
        "crashlytics_triage_export", EXPORT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --- pure transform -------------------------------------------------------

def test_to_triage_shape_maps_fields():
    mod = _load_export_module()
    normalized = [{
        "issue_id": "8afb1c66",
        "title": "BookRegistrySync.saveSync",
        "first_seen_version": "3.2.0",
        "events_count": 8,
        "impacted_users": 6,
    }]
    out = mod.to_triage_shape(normalized)
    assert out == [{
        "id": "8afb1c66",
        "title": "BookRegistrySync.saveSync",
        "errorType": "FATAL",
        "firstSeenVersion": "3.2.0",
        "eventsCount": 8,
        "impactedUsersCount": 6,
    }]


def test_to_triage_shape_drops_idless_rows():
    mod = _load_export_module()
    out = mod.to_triage_shape([{"title": "no id", "events_count": 3}])
    assert out == []


def test_to_triage_shape_coerces_missing_counts_to_zero():
    mod = _load_export_module()
    out = mod.to_triage_shape([{"issue_id": "x", "first_seen_version": "3.2.0"}])
    assert out[0]["eventsCount"] == 0
    assert out[0]["impactedUsersCount"] == 0
    assert out[0]["errorType"] == "FATAL"


# --- end-to-end: snapshot -> export -> gate reads it ----------------------

def test_snapshot_export_feeds_the_gate(tmp_path: Path):
    """A raw API-shaped snapshot flows through the export into a JSON the gate
    consumes and blocks on (the real 3.2.0 saveSync scenario)."""
    # Raw payload shaped like the Crashlytics report the sentinel normalizes.
    raw = {"issues": [{
        "id": "8afb1c66ce5dde59b8774424240af778",
        "title": "BookRegistrySync.saveSync reentrancy deadlock",
        "firstSeenVersion": "3.2.0",
        "eventsCount": 8,
        "impactedUsers": 6,
    }]}
    snap = tmp_path / "raw.json"
    snap.write_text(json.dumps(raw))

    export = subprocess.run(
        [sys.executable, str(EXPORT), "--snapshot", str(snap)],
        capture_output=True, text=True)
    assert export.returncode == 0, export.stderr
    payload = json.loads(export.stdout)
    assert payload["issues"], "export should carry the FATAL signature"
    assert payload["issues"][0]["firstSeenVersion"] == "3.2.0"

    export_file = tmp_path / "export.json"
    export_file.write_text(export.stdout)

    # Un-triaged -> the gate BLOCKS.
    gate = subprocess.run(
        [sys.executable, str(GATE),
         "--release-version", "3.2.0", "--issues-json", str(export_file)],
        capture_output=True, text=True)
    assert gate.returncode == 1, gate.stderr + gate.stdout
    assert "8afb1c66" in gate.stderr


def test_missing_snapshot_is_empty_export(tmp_path: Path):
    """A nonexistent snapshot (mirrors a Firebase outage → empty fetch) yields
    an empty export, so the gate has nothing to block on (soft-fail contract)."""
    export = subprocess.run(
        [sys.executable, str(EXPORT), "--snapshot", str(tmp_path / "nope.json")],
        capture_output=True, text=True)
    assert export.returncode == 0, export.stderr
    assert json.loads(export.stdout) == {"issues": []}


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
