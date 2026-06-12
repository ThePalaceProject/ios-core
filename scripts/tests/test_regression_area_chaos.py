#!/usr/bin/env python3
"""
test_regression_area_chaos.py — pytest for the RC-AREA+CHAOS workstream.

Covers:
  1. The PINNED regression_findings.py module API (palace-pm-ratified): column
     order, append_findings / read_findings / write_findings round-trips,
     missing-key defaulting, header idempotence.
  2. The discovery-layer anti-hallucination rule (append_finding rejects a
     finding with no evidence).
  3. The CLI surface the shell scripts call (append, init-csv, areas, journeys).
  4. Manifest integrity: every journey referenced in .simdrive/regression-areas.json
     exists on disk; every chaos seed is well-formed; classification enum sanity.
  5. Both shell scripts pass `bash -n` (the tooling-checks gate runs this too,
     but failing fast here keeps the workstream self-contained).

Run: pytest scripts/tests/test_regression_area_chaos.py
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPTS = _REPO_ROOT / "scripts"
_MODULE = _SCRIPTS / "regression_findings.py"
_MANIFEST = _REPO_ROOT / ".simdrive" / "regression-areas.json"
_JOURNEYS_DIR = _REPO_ROOT / ".simdrive" / "journeys"
_AREA_WORKER = _SCRIPTS / "regression-area-worker.sh"
_CHAOS_FAN = _SCRIPTS / "regression-chaos-fan.sh"


def _load_module():
    spec = importlib.util.spec_from_file_location("regression_findings", _MODULE)
    mod = importlib.util.module_from_spec(spec)
    # Register before exec so @dataclass introspection (sys.modules lookup) works
    # under Python 3.12+ when loading a module by file path.
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


rf = _load_module()


# ── 1. pinned module API ──────────────────────────────────────────────────────


def test_columns_are_the_pinned_eleven():
    assert rf.FINDINGS_COLUMNS == [
        "id", "area", "device_cell", "severity", "classification", "verified",
        "evidence_paths", "screenshot_pair", "first_seen_commit",
        "dedup_cluster", "disposition",
    ]
    # alias kept for internal callers
    assert rf.FINDINGS_HEADER == rf.FINDINGS_COLUMNS


def test_append_findings_creates_header_and_appends(tmp_path):
    csv_path = str(tmp_path / "shard.csv")
    rf.append_findings(csv_path, [
        {"id": "x-1", "area": "auth", "device_cell": "C-iphone-26",
         "classification": "crash", "evidence_paths": "a.log"},
    ])
    rows = rf.read_findings(csv_path)
    assert len(rows) == 1
    assert rows[0]["id"] == "x-1"
    assert rows[0]["classification"] == "crash"
    # second append does not re-emit a header
    rf.append_findings(csv_path, [
        {"id": "x-2", "area": "auth", "device_cell": "C-iphone-26"},
    ])
    rows = rf.read_findings(csv_path)
    assert [r["id"] for r in rows] == ["x-1", "x-2"]


def test_append_findings_defaults_missing_keys_to_empty(tmp_path):
    csv_path = str(tmp_path / "shard.csv")
    rf.append_findings(csv_path, [{"id": "only-id"}])
    row = rf.read_findings(csv_path)[0]
    # every schema column present; absent inputs are ""
    assert set(row.keys()) == set(rf.FINDINGS_COLUMNS)
    assert row["severity"] == ""
    assert row["dedup_cluster"] == ""
    assert row["disposition"] == ""


def test_append_findings_empty_list_still_writes_header(tmp_path):
    csv_path = str(tmp_path / "empty.csv")
    rf.append_findings(csv_path, [])
    assert Path(csv_path).exists()
    assert rf.read_findings(csv_path) == []
    # header line is the schema
    assert Path(csv_path).read_text().splitlines()[0].split(",") == rf.FINDINGS_COLUMNS


def test_write_findings_full_rewrite_for_triage_upsert(tmp_path):
    csv_path = str(tmp_path / "master.csv")
    rf.append_findings(csv_path, [
        {"id": "a", "classification": "unknown", "severity": ""},
        {"id": "b", "classification": "unknown", "severity": ""},
    ])
    # Triage upserts by id: flip 'a' classification + severity, drop 'b'.
    rows = rf.read_findings(csv_path)
    rows = [r for r in rows if r["id"] != "b"]
    rows[0]["classification"] = "crash"
    rows[0]["severity"] = "blocker"
    rf.write_findings(csv_path, rows)
    after = rf.read_findings(csv_path)
    assert [r["id"] for r in after] == ["a"]
    assert after[0]["classification"] == "crash"
    assert after[0]["severity"] == "blocker"


def test_read_findings_missing_file_returns_empty():
    assert rf.read_findings("/nonexistent/path/findings.csv") == []


def test_evidence_round_trips_through_separators(tmp_path):
    csv_path = str(tmp_path / "shard.csv")
    f = rf.Finding(
        id="e-1", area="reading", device_cell="C-iphone-26",
        classification="visual-parity",
        evidence_paths=["logs/a.log", "logs/a-struct.log"],
        screenshot_pair=("", "candidates/x-final.png"),
    )
    rf.append_finding(csv_path, f)
    row = rf.read_findings(csv_path)[0]
    assert row["evidence_paths"] == "logs/a.log;logs/a-struct.log"
    assert row["screenshot_pair"] == "|candidates/x-final.png"


# ── 2. anti-hallucination ─────────────────────────────────────────────────────


def test_finding_with_no_evidence_is_rejected(tmp_path):
    csv_path = str(tmp_path / "shard.csv")
    bare = rf.Finding(id="z", area="auth", device_cell="C-iphone-26",
                      classification="unknown")
    with pytest.raises(ValueError):
        rf.append_finding(csv_path, bare)
    # allow override for synthetic rows
    rf.append_finding(csv_path, bare, require_evidence=False)
    assert len(rf.read_findings(csv_path)) == 1


def test_bad_classification_rejected():
    f = rf.Finding(id="z", area="auth", device_cell="C-iphone-26",
                   classification="not-a-real-class", evidence_paths=["a.log"])
    with pytest.raises(ValueError):
        f.to_row()


# ── 2b. chaos-row translation (the ingest logic, now testable) ────────────────


def _chaos_row(**over) -> dict:
    base = {
        "ID": "C-1", "Title": "rapid-tap double borrow", "Area": "circulation",
        "Classification": "regression", "Severity": "major", "Verified": "false",
        "Screenshot Baseline": "", "Screenshot Candidate": "", "Notes": "",
    }
    base.update(over)
    return base


def test_translate_chaos_row_basic_maps_to_campaign_schema():
    f = rf.translate_chaos_row(
        _chaos_row(), finding_id="chaos-circulation-C-iphone-26-000",
        area="circulation", device_cell="C-iphone-26",
        run_evidence=["chaos/findings.csv"], first_seen_commit="abc123",
    )
    assert f is not None
    row = f.to_row()
    # legacy 'regression' is NOT in the campaign enum → 'other'
    assert row["classification"] == "other"
    assert row["area"] == "circulation"
    assert row["device_cell"] == "C-iphone-26"
    assert row["severity"] == "major"
    assert row["evidence_paths"] == "chaos/findings.csv"
    assert row["first_seen_commit"] == "abc123"
    assert row["verified"] == "false"


def test_translate_chaos_row_crash_in_title_forces_crash_class():
    f = rf.translate_chaos_row(
        _chaos_row(Title="app CRASH on background", Classification=""),
        finding_id="x", area="auth", device_cell="C-iphone-26",
        run_evidence=["a.log"],
    )
    assert f.classification == "crash"


def test_translate_chaos_row_crash_in_notes_forces_crash_class():
    f = rf.translate_chaos_row(
        _chaos_row(Title="weird state", Notes="led to a crash report"),
        finding_id="x", area="auth", device_cell="C-iphone-26",
        run_evidence=["a.log"],
    )
    assert f.classification == "crash"


def test_translate_chaos_row_keeps_valid_enum_classification():
    f = rf.translate_chaos_row(
        _chaos_row(Classification="perf"),
        finding_id="x", area="auth", device_cell="C-iphone-26",
        run_evidence=["a.log"],
    )
    assert f.classification == "perf"


def test_translate_chaos_row_blank_title_returns_none():
    assert rf.translate_chaos_row(
        _chaos_row(Title="  "), finding_id="x", area="auth",
        device_cell="C-iphone-26", run_evidence=["a.log"],
    ) is None


def test_translate_chaos_row_screenshot_pair_when_cited():
    f = rf.translate_chaos_row(
        _chaos_row(**{"Screenshot Baseline": "b.png", "Screenshot Candidate": "c.png"}),
        finding_id="x", area="auth", device_cell="C-iphone-26",
        run_evidence=["a.log"],
    )
    assert f.screenshot_pair == ("b.png", "c.png")


def test_translate_chaos_row_no_evidence_is_discarded_on_append(tmp_path):
    # A row with no run evidence AND no screenshot → translate returns a Finding
    # with empty evidence; append_finding rejects it (the ingest loop's discard).
    csv_path = str(tmp_path / "shard.csv")
    f = rf.translate_chaos_row(
        _chaos_row(), finding_id="x", area="auth", device_cell="C-iphone-26",
        run_evidence=[],
    )
    assert f is not None and not f.has_evidence()
    with pytest.raises(ValueError):
        rf.append_finding(csv_path, f)


# ── 2c. crashes_since — pins the DEFECT-1 since_ts fix ────────────────────────


def test_crashes_since_only_returns_post_start_crashes():
    # A crash BEFORE the run start must never count; one AFTER must.
    start_ts = 1000.0
    reports = [
        {"timestamp": "old", "mtime": 900.0},   # predates the run → excluded
        {"timestamp": "new", "mtime": 1100.0},  # during the run → included
    ]
    kept = rf.crashes_since(reports, start_ts)
    assert len(kept) == 1
    assert kept[0]["timestamp"] == "new"


def test_crashes_since_boundary_is_inclusive():
    # A crash exactly at start_ts counts (>= comparison).
    assert len(rf.crashes_since([{"mtime": 1000.0}], 1000.0)) == 1


def test_crashes_since_no_mtime_is_failopen_kept():
    # A report with no usable mtime is kept (better to surface than drop a crash).
    kept = rf.crashes_since([{"timestamp": "x"}], 1000.0)
    assert len(kept) == 1


def test_crashes_since_empty_is_empty():
    assert rf.crashes_since([], 1000.0) == []


def test_read_findings_tolerates_malformed_csv(tmp_path):
    # A short/ragged row must not crash read_findings; missing cols come back as
    # None/"" per csv.DictReader, never an exception.
    p = tmp_path / "bad.csv"
    p.write_text(",".join(rf.FINDINGS_COLUMNS) + "\n" + "only-id,auth\n")
    rows = rf.read_findings(str(p))
    assert rows[0]["id"] == "only-id"
    assert rows[0]["area"] == "auth"


# ── 2d. classify_replay — the anti-false-pass guard (the #1 integrity gate) ───


def test_classify_replay_full_clean_is_pass():
    r = {"ok": True, "steps_planned": 3,
         "steps": [{"executed": True}, {"executed": True}, {"executed": True}]}
    v = rf.classify_replay(r)
    assert v["status"] == "pass"
    assert v["steps_executed"] == 3 and v["steps_planned"] == 3


def test_classify_replay_state_contract_halt_is_fail_not_pass():
    # The EXACT shape that previously false-passed: replay halted at step 0 on a
    # state-contract mismatch → steps:[] but steps_planned stays N.
    r = {"ok": False, "halted_at": 0, "halt_reason": "state_contract_mismatch",
         "steps_planned": 11, "steps": []}
    v = rf.classify_replay(r)
    assert v["status"] == "fail"          # NEVER pass
    assert v["steps_executed"] == 0
    assert "state_contract_mismatch" in v["reason"]
    assert "0/11" in v["reason"]


def test_classify_replay_incomplete_is_fail():
    r = {"ok": True, "steps_planned": 11,
         "steps": [{"executed": True}] * 5}   # only 5 of 11 ran
    v = rf.classify_replay(r)
    assert v["status"] == "fail"
    assert "5/11" in v["reason"]


def test_classify_replay_errored_step_is_fail():
    r = {"ok": True, "steps_planned": 2,
         "steps": [{"executed": True}, {"executed": True, "error": "tap missed"}]}
    v = rf.classify_replay(r)
    assert v["status"] == "fail"
    assert v["errored"] == 1


def test_classify_replay_zero_planned_is_error():
    r = {"ok": True, "steps_planned": 0, "steps": []}
    v = rf.classify_replay(r)
    assert v["status"] == "error"
    assert "misconfiguration" in v["reason"]


def test_classify_replay_drift_only_is_still_pass():
    # Drift is informational on OPDS screens — executed+complete+no-error = pass.
    r = {"ok": True, "steps_planned": 2,
         "steps": [{"executed": True, "drifted": True},
                   {"executed": True, "drifted": True}]}
    v = rf.classify_replay(r)
    assert v["status"] == "pass"
    assert v["drifted"] == 2


def test_classify_replay_compat_no_executed_flag_counts_present_steps():
    # Older result shapes omit the `executed` flag; present results count.
    r = {"steps_planned": 2, "steps": [{"id": 1}, {"id": 2}]}
    v = rf.classify_replay(r)
    assert v["steps_executed"] == 2 and v["status"] == "pass"


def test_classify_replay_missing_steps_planned_falls_back_to_len():
    r = {"steps": [{"executed": True}, {"executed": True}]}
    v = rf.classify_replay(r)
    assert v["steps_planned"] == 2 and v["status"] == "pass"


# ── 2e. device-suffix normalization (campaign-critical) ───────────────────────


def test_strip_device_suffix():
    assert rf.strip_device_suffix("iPhone 16 Pro (pool-3)") == "iPhone 16 Pro"
    assert rf.strip_device_suffix("iPhone 16 Pro (fleet-5)") == "iPhone 16 Pro"
    assert rf.strip_device_suffix("iPhone 16 Pro") == "iPhone 16 Pro"
    assert rf.strip_device_suffix("") == ""


def test_device_matches_modulo_suffix():
    assert rf.device_matches_modulo_suffix("iPhone 16 Pro", "iPhone 16 Pro (pool-3)")
    assert rf.device_matches_modulo_suffix("iPhone 16 Pro (pool-3)", "iPhone 16 Pro (fleet-5)")
    assert not rf.device_matches_modulo_suffix("iPhone 16 Pro", "iPad Pro")
    assert not rf.device_matches_modulo_suffix("", "iPhone 16 Pro")


def test_normalized_requires_device_rewrites_to_current_on_suffix_only():
    # base recording + suffixed fleet sim, same model → rewrite to current name
    assert rf.normalized_requires_device(
        "iPhone 16 Pro", "iPhone 16 Pro (pool-3)") == "iPhone 16 Pro (pool-3)"


def test_normalized_requires_device_none_when_already_equal():
    assert rf.normalized_requires_device(
        "iPhone 16 Pro (pool-3)", "iPhone 16 Pro (pool-3)") is None
    assert rf.normalized_requires_device("iPhone 16 Pro", "iPhone 16 Pro") is None


def test_normalized_requires_device_none_on_real_model_divergence():
    # SAFETY: a genuinely different model must NOT be normalized — a real
    # device-divergence must still HALT/FAIL, not be masked.
    assert rf.normalized_requires_device("iPhone 16 Pro", "iPad Pro (pool-3)") is None
    assert rf.normalized_requires_device("iPhone 16 Pro", "iPhone 15 (pool-3)") is None


def test_normalized_requires_device_none_on_empty():
    assert rf.normalized_requires_device("", "iPhone 16 Pro") is None
    assert rf.normalized_requires_device("iPhone 16 Pro", "") is None


# ── 3. CLI surface used by the shell scripts ──────────────────────────────────


def _cli(*args) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(_MODULE), *args],
        capture_output=True, text=True,
    )


def test_cli_append_and_init(tmp_path):
    csv_path = str(tmp_path / "shard.csv")
    r = _cli("init-csv", csv_path)
    assert r.returncode == 0
    r = _cli("append", csv_path, "--id", "cli-1", "--area", "auth",
             "--device-cell", "C-iphone-26", "--classification", "crash",
             "--evidence", "logs/x.log;crashes/x.json")
    assert r.returncode == 0, r.stderr
    rows = rf.read_findings(csv_path)
    assert rows[0]["id"] == "cli-1"
    assert rows[0]["evidence_paths"] == "logs/x.log;crashes/x.json"


def test_cli_append_no_evidence_fails_without_override(tmp_path):
    csv_path = str(tmp_path / "shard.csv")
    r = _cli("append", csv_path, "--id", "cli-2", "--area", "auth",
             "--device-cell", "C-iphone-26")
    assert r.returncode == 2
    assert "no evidence" in r.stderr.lower()


def test_cli_areas_and_journeys_resolve():
    r = _cli("areas", str(_MANIFEST))
    assert r.returncode == 0
    areas = r.stdout.split()
    assert "auth" in areas and "circulation" in areas and "audiobook" in areas
    r = _cli("journeys", str(_MANIFEST), "auth")
    assert r.returncode == 0
    assert "a1qa-basic-signin" in r.stdout


def test_cli_unknown_area_group_errors():
    r = _cli("journeys", str(_MANIFEST), "no-such-group")
    assert r.returncode != 0


# ── 4. manifest integrity ─────────────────────────────────────────────────────


def test_every_referenced_journey_exists_on_disk():
    manifest = rf.load_manifest(_MANIFEST)
    missing = []
    for area in rf.area_group_names(manifest):
        for j in rf.journeys_for_area(manifest, area):
            if not (_JOURNEYS_DIR / f"{j}.yaml").exists():
                missing.append(f"{area}:{j}")
    assert not missing, f"manifest references journeys with no YAML: {missing}"


def test_manifest_has_expected_area_groups():
    manifest = rf.load_manifest(_MANIFEST)
    groups = set(rf.area_group_names(manifest))
    expected = {"auth", "circulation", "reading", "audiobook", "catalog", "ui-nav"}
    assert expected <= groups, f"missing area-groups: {expected - groups}"


def test_chaos_seeds_well_formed():
    manifest = rf.load_manifest(_MANIFEST)
    for area in rf.area_group_names(manifest):
        seeds = rf.chaos_seeds_for_area(manifest, area)
        assert seeds, f"area '{area}' has no chaos seeds"
        for s in seeds:
            # either the universal fallback or a flow/step pair
            assert s == "cold-launch" or "/" in s, f"malformed seed {s!r} in {area}"


def test_every_area_has_at_least_one_journey():
    manifest = rf.load_manifest(_MANIFEST)
    for area in rf.area_group_names(manifest):
        assert rf.journeys_for_area(manifest, area), f"area '{area}' has no journeys"


# ── 5. shell scripts parse ────────────────────────────────────────────────────


@pytest.mark.parametrize("script", [_AREA_WORKER, _CHAOS_FAN])
def test_shell_scripts_pass_bash_n(script):
    r = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


@pytest.mark.parametrize("script", [_AREA_WORKER, _CHAOS_FAN])
def test_no_unguarded_empty_array_expansion(script):
    # bash 3.2 (macOS default) throws "unbound variable" on "${arr[@]}" under
    # `set -u` when arr is empty. These arrays are conditionally populated, so
    # every expansion MUST use the "${arr[@]+...}" guard form. (A real chaos run
    # surfaced this for dry_arg; bash -n does NOT catch it.)
    import re
    text = script.read_text()
    for arr in ("dry_arg", "sshot_arg", "seed_args"):
        # Unsafe: "${arr[@]}" NOT preceded by '+' (the guard form is
        # "${arr[@]+"${arr[@]}"}", whose inner copy IS preceded by '+"').
        unsafe = re.compile(r'(?<!\+)"\$\{' + re.escape(arr) + r'\[@\]\}"')
        assert not unsafe.search(text), (
            f"{script.name}: unguarded \"${{{arr}[@]}}\" crashes under set -u in "
            f'bash 3.2; use "${{{arr}[@]+"${{{arr}[@]}}"}}"'
        )


@pytest.mark.parametrize("script", [_AREA_WORKER, _CHAOS_FAN])
def test_shell_scripts_dry_run_help(script):
    # --help must exit 0 and not require a sim
    r = subprocess.run(["bash", str(script), "--help"], capture_output=True, text=True)
    assert r.returncode == 0
    assert "Usage" in r.stdout or "usage" in r.stdout


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
