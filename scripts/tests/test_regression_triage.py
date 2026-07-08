#!/usr/bin/env python3
"""Pytest for scripts/regression-triage.py (Stage-4 deterministic triage layer).

Tests behaviour, not structure: every assertion fails if a real classification /
severity / disposition / dedup decision regresses. These are the mutation
targets — flip a conditional in the production code and one of these reds.
"""
import copy
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURE = SCRIPTS / "tests" / "fixtures" / "regression-findings-sample.csv"

# Load the hyphenated module by path.
_spec = importlib.util.spec_from_file_location(
    "regression_triage", SCRIPTS / "regression-triage.py")
triage = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(triage)


@pytest.fixture
def rows():
    return triage.load_findings(FIXTURE)


@pytest.fixture
def triaged(rows):
    return triage.triage_findings(copy.deepcopy(rows))


def _by_id(triaged):
    return {r["id"]: r for r in triaged}


# --- classification (taxonomy attribution) ---------------------------------

def test_recursive_mutex_crash_is_device_divergence(triaged):
    assert _by_id(triaged)["F-001"]["classification"] == "device-divergence"


def test_lane_skeleton_diff_is_visual_parity(triaged):
    assert _by_id(triaged)["F-003"]["classification"] == "visual-parity"


def test_keychain_log_is_keychain_auth_state(triaged):
    assert _by_id(triaged)["F-005"]["classification"] == "keychain-auth-state"


def test_loadcatalogs_pool_starvation_is_defer_flag(triaged):
    assert _by_id(triaged)["F-006"]["classification"] == "defer-flag"


def test_evidenced_but_unsignalled_is_other(triaged):
    # F-008 has a log but no taxonomy signal -> 'other' (a real, uncategorised
    # finding), NOT 'unknown'.
    assert _by_id(triaged)["F-008"]["classification"] == "other"


def test_no_evidence_stays_unknown(triaged):
    assert _by_id(triaged)["F-007"]["classification"] == "unknown"


def test_perf_log_is_perf(triaged):
    assert _by_id(triaged)["F-009"]["classification"] == "perf"


def test_every_row_classified_in_enum(triaged):
    for r in triaged:
        assert r["classification"] in triage.CLASSIFICATIONS


# --- severity ---------------------------------------------------------------

def test_device_divergence_is_blocker(triaged):
    assert _by_id(triaged)["F-001"]["severity"] == "blocker"


def test_visual_parity_on_lane_is_major(triaged):
    assert _by_id(triaged)["F-003"]["severity"] == "major"


def test_pollution_red_at_3_escalates_to_major(triaged):
    # keychain red@3 reddens the board -> major (not minor).
    assert _by_id(triaged)["F-005"]["severity"] == "major"


def test_pollution_green_at_3_stays_minor(triaged):
    assert _by_id(triaged)["F-006"]["severity"] == "minor"


# --- disposition ------------------------------------------------------------

def test_verified_product_crash_files_jira(triaged):
    assert _by_id(triaged)["F-001"]["disposition"] == "file-jira"


def test_no_evidence_is_dropped(triaged):
    assert _by_id(triaged)["F-007"]["disposition"] == "drop"


def test_unverified_product_finding_needs_verify(triaged):
    assert _by_id(triaged)["F-008"]["disposition"] == "needs-verify"


def test_pollution_red_at_3_files_jira(triaged):
    assert _by_id(triaged)["F-005"]["disposition"] == "file-jira"


def test_pollution_green_at_3_is_flake_ticket(triaged):
    assert _by_id(triaged)["F-006"]["disposition"] == "ticket-as-flake"


def test_every_row_dispositioned_in_enum(triaged):
    for r in triaged:
        assert r["disposition"] in triage.DISPOSITIONS


# --- the verified gate actually gates (mutation guard) ----------------------

def test_flipping_verified_true_flips_needs_verify_to_file_jira(rows):
    rows = copy.deepcopy(rows)
    for r in rows:
        if r["id"] == "F-008":
            r["verified"] = "true"
    out = _by_id(triage.triage_findings(rows))
    assert out["F-008"]["disposition"] == "file-jira"


def test_flipping_red3_to_green3_changes_pollution_disposition(rows):
    rows = copy.deepcopy(rows)
    for r in rows:
        if r["id"] == "F-005":
            r["evidence_paths"] = r["evidence_paths"].replace("red@3", "green@3")
    out = _by_id(triage.triage_findings(rows))
    assert out["F-005"]["disposition"] == "ticket-as-flake"
    assert out["F-005"]["severity"] == "minor"


# --- dedup clustering -------------------------------------------------------

def test_same_crash_family_across_findings_one_cluster(triaged):
    bid = _by_id(triaged)
    assert bid["F-001"]["dedup_cluster"] == bid["F-002"]["dedup_cluster"]


def test_same_visual_area_across_cells_one_cluster(triaged):
    # F-003 (iphone) and F-004 (ipad) are the same lane-skeleton root.
    bid = _by_id(triaged)
    assert bid["F-003"]["dedup_cluster"] == bid["F-004"]["dedup_cluster"]


def test_distinct_roots_get_distinct_clusters(triaged):
    bid = _by_id(triaged)
    assert bid["F-001"]["dedup_cluster"] != bid["F-003"]["dedup_cluster"]


def test_clustering_is_idempotent(rows):
    once = _by_id(triage.triage_findings(copy.deepcopy(rows)))
    twice = _by_id(triage.triage_findings(copy.deepcopy(rows)))
    for fid in once:
        assert once[fid]["dedup_cluster"] == twice[fid]["dedup_cluster"]


# --- Fable bridge -----------------------------------------------------------

def test_emit_fable_input_carries_baseline_and_evidence(triaged):
    bundle = triage.build_fable_input(triaged)
    assert bundle["schema"] == triage.FIELDNAMES
    f1 = next(f for f in bundle["findings"] if f["id"] == "F-001")
    assert f1["deterministic_baseline"]["classification"] == "device-divergence"
    assert "recursive_mutex" in f1["evidence_paths"]


def test_apply_fable_overrides_in_enum_value(triaged):
    fable = {"findings": [
        {"id": "F-008", "classification": "crash", "severity": "blocker",
         "disposition": "file-jira"}]}
    changed = triage.apply_fable_output(triaged, fable)
    assert "F-008" in changed
    out = _by_id(triaged)["F-008"]
    assert out["classification"] == "crash"
    assert out["severity"] == "blocker"
    assert out["disposition"] == "file-jira"


def test_apply_fable_rejects_out_of_enum(triaged):
    before = _by_id(triaged)["F-001"]["classification"]
    fable = {"findings": [{"id": "F-001", "classification": "not-a-real-class"}]}
    triage.apply_fable_output(triaged, fable)
    assert _by_id(triaged)["F-001"]["classification"] == before  # unchanged


def test_apply_fable_unknown_id_is_noop(triaged):
    changed = triage.apply_fable_output(
        triaged, {"findings": [{"id": "F-999", "severity": "blocker"}]})
    assert changed == []


# --- full CLI round-trip ----------------------------------------------------

def test_cli_writes_triaged_csv(tmp_path):
    src = tmp_path / "findings.csv"
    src.write_text(FIXTURE.read_text(encoding="utf-8"), encoding="utf-8")
    rc = triage.main(["--csv", str(src)])
    assert rc == 0
    out = triage.load_findings(src)
    for r in out:
        assert r["severity"] and r["classification"] and r["disposition"]
        assert r["dedup_cluster"]


def test_empty_csv_is_error(tmp_path):
    src = tmp_path / "empty.csv"
    src.write_text(",".join(triage.FIELDNAMES) + "\n", encoding="utf-8")
    assert triage.main(["--csv", str(src)]) == 3


# --- cross-module schema contract (QA-required, #1077 SoD) ------------------

def test_fieldnames_match_shared_module_column_order():
    # The campaign's linchpin: triage's column list must equal the shared
    # module's, IN ORDER. A future schema reorder in regression_findings.py
    # would silently misalign every triaged CSV without this list-equality pin.
    assert triage.FIELDNAMES == list(triage.rf.FINDINGS_COLUMNS)
    assert triage.CLASSIFICATIONS == set(triage.rf.FINDING_CLASSIFICATIONS)


def test_triage_output_roundtrips_through_real_module(tmp_path):
    # Triage writes via rf.write_findings; read it back via the REAL module
    # directly (NOT triage.load_findings) and confirm keys + the 4 triage values
    # survived the round-trip. Mirrors #1075/#1076's cross-module round-trip.
    src = tmp_path / "findings.csv"
    src.write_text(FIXTURE.read_text(encoding="utf-8"), encoding="utf-8")
    assert triage.main(["--csv", str(src)]) == 0
    rows = triage.rf.read_findings(str(src))           # real module, not my wrapper
    by_id = {r["id"]: r for r in rows}
    assert set(by_id["F-001"].keys()) >= set(triage.rf.FINDINGS_COLUMNS)
    assert by_id["F-001"]["classification"] == "device-divergence"
    assert by_id["F-001"]["severity"] == "blocker"
    assert by_id["F-001"]["disposition"] == "file-jira"
    assert by_id["F-001"]["dedup_cluster"]             # non-empty cluster id
    # the on-disk header is exactly the contract column order
    header = src.read_text(encoding="utf-8").splitlines()[0].split(",")
    assert header == list(triage.rf.FINDINGS_COLUMNS)


def _run_isolated_without_shared_module(script_name, tmp_path, extra_args=()):
    """Copy ONLY the script into an isolated dir (no regression_findings.py
    beside it) and run it with an empty PYTHONPATH, so `import regression_findings`
    cannot resolve — proving there is no silent fallback."""
    iso = tmp_path / "iso"
    iso.mkdir()
    shutil.copy(SCRIPTS / script_name, iso / script_name)
    csv = iso / "f.csv"
    csv.write_text("id,area\nF-1,x\n", encoding="utf-8")
    env = {**os.environ, "PYTHONPATH": ""}
    return subprocess.run(
        [sys.executable, str(iso / script_name), "--csv", str(csv), *extra_args],
        capture_output=True, text=True, env=env, cwd=str(iso))


def test_triage_hard_errors_without_shared_module(tmp_path):
    r = _run_isolated_without_shared_module("regression-triage.py", tmp_path)
    assert r.returncode != 0
    assert "ModuleNotFoundError" in r.stderr and "regression_findings" in r.stderr
