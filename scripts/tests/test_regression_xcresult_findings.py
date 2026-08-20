#!/usr/bin/env python3
"""
test_regression_xcresult_findings.py — pytest for
scripts/regression_xcresult_findings.py (the headless-XCTest-cell findings
parser used by C-carplay).

Asserts:
  - crash-vs-assertion classification from xcresult `failureText`;
  - testFailures[] → normalized (suite, test, identifier);
  - PASS (no failures) emits no shard;
  - failures emit own-shard rows in the pinned schema, with crash→blocker and
    assertion→major severity.

Fixtures mirror the REAL `xcresulttool get test-results summary --format json`
shape: a top-level dict with `totalTestCount` and a `testFailures` list of
{failureText, targetName, testIdentifierString, testName}.
"""
from __future__ import annotations

import csv
import importlib.util
from pathlib import Path

import pytest

_SCRIPTS = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "regression_xcresult_findings", _SCRIPTS / "regression_xcresult_findings.py"
)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)


def _failure(ident, text, target="PalaceTests"):
    suite, _, method = ident.partition("/")
    return {
        "failureText": text,
        "targetName": target,
        "testIdentifierString": ident,
        "testName": method,
    }


CRASH = _failure("CarPlayTests/testCarPlay_OpensBook()", "Test crashed with signal trap.")
ASSERT = _failure("CarPlayTests/testCarPlay_LibraryName()", "XCTAssertEqual failed: (\"a\") is not equal to (\"b\")")
FATAL = _failure("CarPlayTests/testBridge_x()", "Fatal error: Unexpectedly found nil")


# --- classification ----------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("Test crashed with signal trap.", "crash"),
    ("Fatal error: Unexpectedly found nil", "crash"),
    ("Thread 1: EXC_BAD_ACCESS", "crash"),
    ("terminating with uncaught exception", "crash"),
    ("XCTAssertNotNil failed", "other"),
    ("XCTAssertEqual failed", "other"),
    ("", "other"),
])
def test_classify_failure(text, expected):
    assert mod.classify_failure(text) == expected


# --- parse -------------------------------------------------------------------

def test_parse_failures_splits_suite_and_method():
    summary = {"totalTestCount": 40, "testFailures": [CRASH, ASSERT]}
    got = mod.parse_failures(summary)
    assert len(got) == 2
    assert got[0]["suite"] == "CarPlayTests"
    assert got[0]["test"] == "testCarPlay_OpensBook()"
    assert got[0]["classification"] == "crash"
    assert got[1]["classification"] == "other"


def test_parse_no_failures_is_empty():
    assert mod.parse_failures({"totalTestCount": 40, "testFailures": []}) == []
    assert mod.parse_failures({"totalTestCount": 40}) == []  # key absent


# --- rows + severity ---------------------------------------------------------

def test_build_rows_severity_by_class():
    failures = mod.parse_failures({"testFailures": [CRASH, ASSERT, FATAL]})
    rows = mod.build_rows(failures, "C-carplay", "carplay", "x.xcresult", "abc123")
    sev = {r["classification"]: r["severity"] for r in rows}
    assert sev["crash"] == "blocker"
    assert sev["other"] == "major"
    assert all(r["device_cell"] == "C-carplay" for r in rows)
    assert all(r["evidence_paths"] == "x.xcresult" for r in rows)


# --- emission (own shard, pinned schema) -------------------------------------

_EXPECTED_COLUMNS = [
    "id", "area", "device_cell", "severity", "classification", "verified",
    "evidence_paths", "screenshot_pair", "first_seen_commit", "dedup_cluster",
    "disposition", "suspected_cause", "cause_status",
]


def test_emit_writes_own_shard_with_schema(tmp_path):
    failures = mod.parse_failures({"testFailures": [CRASH, ASSERT]})
    rows = mod.build_rows(failures, "C-carplay", "carplay", "x.xcresult", "abc")
    shard = mod.emit_findings(str(tmp_path / "run"), "C-carplay", "carplay", rows)
    assert Path(shard).name == "C-carplay__carplay.csv"
    out = list(csv.DictReader(Path(shard).open()))
    assert len(out) == 2
    assert list(out[0].keys()) == _EXPECTED_COLUMNS  # schema/order conformance
    assert out[0]["classification"] == "crash"
    assert out[0]["severity"] == "blocker"


def test_pass_emits_no_shard(tmp_path):
    shard = mod.emit_findings(str(tmp_path / "run"), "C-carplay", "carplay", [])
    assert shard is None


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
