#!/usr/bin/env python3
"""Pytest for the campaign EXECUTION-evidence chain.

Covers scripts/regression_shard_record.py, the coverage verdict in
scripts/generate-regression-campaign-report.py, and the wiring in
scripts/regression-area-worker.sh that produces the records.

The defect being closed: findings.csv records what a campaign FOUND, and
nothing recorded what it RAN, so a run that skipped all 96 journeys rendered
identically to a clean regression. Every test below is about keeping those two
outcomes distinguishable.
"""
from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"
WORKER = SCRIPTS / "regression-area-worker.sh"
REPORT_SCRIPT = SCRIPTS / "generate-regression-campaign-report.py"
FIXTURE = SCRIPTS / "tests" / "fixtures" / "regression-findings-sample.csv"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, mod)
    spec.loader.exec_module(mod)
    return mod


rsr = _load("regression_shard_record", SCRIPTS / "regression_shard_record.py")
report = _load("regression_campaign_report", REPORT_SCRIPT)
findings = _load("regression_findings", SCRIPTS / "regression_findings.py")


# --- the record itself ------------------------------------------------------

def test_record_carries_executed_units_and_wall_clock(tmp_path):
    path = rsr.write_record(str(tmp_path), area="auth", device_cell="C-iphone-26",
                            passed=3, failed=1, skipped=2,
                            started_at=1000.0, ended_at=1090.0)
    rec = json.loads(Path(path).read_text())
    assert rec["executed"] == 4, "executed = passed + failed; skips are not work"
    assert rec["skipped"] == 2
    assert rec["elapsed_s"] == 90.0


def test_records_are_per_shard_so_parallel_workers_do_not_race(tmp_path):
    rsr.write_record(str(tmp_path), area="auth", device_cell="C-iphone-26",
                     passed=1, failed=0, skipped=0)
    rsr.write_record(str(tmp_path), area="auth", device_cell="C-ipad-26",
                     passed=1, failed=0, skipped=0)
    rsr.write_record(str(tmp_path), area="reading", device_cell="C-iphone-26",
                     passed=1, failed=0, skipped=0)
    assert len(rsr.load_records(rsr.shards_dir(str(tmp_path)))) == 3


def test_load_records_skips_a_corrupt_file_instead_of_exploding(tmp_path):
    rsr.write_record(str(tmp_path), area="auth", device_cell="C-iphone-26",
                     passed=1, failed=0, skipped=0)
    (Path(rsr.shards_dir(str(tmp_path))) / "junk.json").write_text("{not json")
    assert len(rsr.load_records(rsr.shards_dir(str(tmp_path)))) == 1


def test_implausibly_fast_shard_is_flagged():
    """21 shards in 25 seconds was the tell nobody read."""
    fast = {"passed": 4, "failed": 0, "executed": 4, "elapsed_s": 1.2}
    slow = {"passed": 4, "failed": 0, "executed": 4, "elapsed_s": 240.0}
    assert rsr.is_implausibly_fast(fast)
    assert not rsr.is_implausibly_fast(slow)


def test_zero_executed_shard_has_no_rate_rather_than_a_fake_one():
    assert rsr.seconds_per_unit({"executed": 0, "elapsed_s": 3.0}) is None
    assert not rsr.is_implausibly_fast({"executed": 0, "elapsed_s": 0.1})


# --- the verdict ------------------------------------------------------------

def _rows(n: int):
    return [{c: "" for c in report.FINDINGS_COLUMNS} for _ in range(n)]


def _recs(**kw):
    base = {"area": "auth", "device_cell": "C-iphone-26", "passed": 0,
            "failed": 0, "skipped": 0, "executed": 0, "elapsed_s": 0.0,
            "exit_code": 0}
    base.update(kw)
    return [base]


def test_verdict_refuses_when_every_shard_executed_nothing():
    v = report.coverage_verdict(_rows(0), _recs(skipped=96))
    assert v == report.VERDICT_NO_EXECUTION


def test_verdict_refuses_on_no_findings_and_no_execution_evidence():
    assert report.coverage_verdict(_rows(0), []) == report.VERDICT_NO_EVIDENCE


def test_verdict_accepts_a_genuinely_clean_run():
    """0 findings + executed work IS a pass. The gate must not block those."""
    v = report.coverage_verdict(_rows(0), _recs(passed=6, executed=6, elapsed_s=300.0))
    assert v == report.VERDICT_OK


def test_verdict_renders_when_findings_exist_without_records():
    """The campaign demonstrably did work; render it, do not refuse."""
    assert report.coverage_verdict(_rows(3), []) == report.VERDICT_OK


def test_refusal_banner_is_in_the_html_artifact():
    html = report.render(_rows(0), run_id="r", assets_root=".",
                         records=_recs(skipped=96))
    assert "NO VERDICT" in html
    assert "regression-preflight.sh" in html, "banner must name the diagnosis command"


def test_clean_report_has_no_refusal_banner():
    html = report.render(_rows(0), run_id="r", assets_root=".",
                         records=_recs(passed=6, executed=6, elapsed_s=300.0))
    assert "NO VERDICT" not in html


def test_elapsed_per_shard_is_surfaced_in_the_artifact():
    html = report.render(_rows(0), run_id="r", assets_root=".",
                         records=_recs(passed=4, executed=4, elapsed_s=1.0))
    assert "Execution (what actually ran)" in html
    assert "0.25s/unit" in html, "per-unit rate must be visible, not just total time"
    assert "too fast to have" in html


def test_render_without_records_says_coverage_is_unverified():
    html = report.render(_rows(2), run_id="r", assets_root=".", records=[])
    assert "UNVERIFIED" in html


# --- the CLI fails closed ---------------------------------------------------

def _run_report(csv_path: Path, out: Path, *extra: str):
    return subprocess.run(
        [sys.executable, str(REPORT_SCRIPT), "--csv", str(csv_path),
         "--output", str(out), *extra],
        capture_output=True, text=True, cwd=str(REPO), timeout=60)


def test_cli_exits_non_zero_and_loudly_on_zero_executed(tmp_path):
    csv_path = tmp_path / "findings.csv"
    findings.ensure_findings_header(str(csv_path))
    rsr.write_record(str(tmp_path), area="auth", device_cell="C-iphone-26",
                     passed=0, failed=0, skipped=8)
    rc = _run_report(csv_path, tmp_path / "report.html")
    assert rc.returncode == report.REFUSAL_EXIT, rc.stdout + rc.stderr
    assert "NO VERDICT" in rc.stderr
    assert "regression-preflight.sh" in rc.stderr, "must name the diagnosis command"
    assert (tmp_path / "report.html").is_file(), \
        "the artifact is still written — with the banner — so the refusal is visible"


def test_cli_exits_zero_on_a_real_run(tmp_path):
    csv_path = tmp_path / "findings.csv"
    findings.ensure_findings_header(str(csv_path))
    rsr.write_record(str(tmp_path), area="auth", device_cell="C-iphone-26",
                     passed=6, failed=0, skipped=0,
                     started_at=1000.0, ended_at=1400.0)
    rc = _run_report(csv_path, tmp_path / "report.html")
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_cli_finds_the_shards_dir_without_being_told(tmp_path):
    """Systemic, not opt-in: the verdict must not depend on remembering a flag.

    The default is <csv-dir>/shards, which is where the worker writes.
    """
    csv_path = tmp_path / "findings.csv"
    findings.ensure_findings_header(str(csv_path))
    rsr.write_record(str(tmp_path), area="auth", device_cell="C-iphone-26",
                     passed=0, failed=0, skipped=8)
    rc = _run_report(csv_path, tmp_path / "report.html")   # no --shards
    assert rc.returncode == report.REFUSAL_EXIT, \
        "default --shards lookup did not find the records"


def test_cli_warns_on_an_implausibly_fast_but_non_empty_run(tmp_path):
    csv_path = tmp_path / "findings.csv"
    findings.ensure_findings_header(str(csv_path))
    rsr.write_record(str(tmp_path), area="auth", device_cell="C-iphone-26",
                     passed=21, failed=0, skipped=0,
                     started_at=1000.0, ended_at=1025.0)
    rc = _run_report(csv_path, tmp_path / "report.html")
    assert rc.returncode == 0, "an implausible rate is a warning, not a refusal"
    assert "implausibly fast" in rc.stderr


def test_existing_fixture_report_still_renders(tmp_path):
    """Regression guard on the pre-existing behaviour: a report WITH findings
    and no execution records must still be produced."""
    rc = _run_report(FIXTURE, tmp_path / "report.html")
    assert rc.returncode == 0, rc.stdout + rc.stderr
    assert (tmp_path / "report.html").read_text().startswith("<!DOCTYPE html>")


# --- worker wiring ----------------------------------------------------------

def test_worker_writes_a_shard_record_on_both_exit_paths():
    """RED if someone removes either call.

    Two exits matter: the NO-COVERAGE `exit 3` and the clean tail. A record
    written on only one of them means the campaign report's evidence goes
    missing on exactly the runs that need it most.
    """
    text = WORKER.read_text(encoding="utf-8")
    assert "regression_shard_record.py" in text, \
        "the worker no longer produces execution records"
    calls = [m.start() for m in re.finditer(r"^\s*write_shard_record\b", text, re.M)]
    assert len(calls) >= 2, f"expected a record on every exit path, found {len(calls)}"

    no_coverage = text.index("!!! NO COVERAGE")
    exit3 = text.index("exit 3", no_coverage)
    assert any(no_coverage < c < exit3 for c in calls), \
        "the NO-COVERAGE path exits 3 without recording that it executed nothing"

    tail = text.rindex("exit 0")
    assert any(c < tail for c in calls)


def test_worker_shard_record_helper_passes_the_real_counters():
    text = WORKER.read_text(encoding="utf-8")
    body = text[text.index("write_shard_record() {"):]
    body = body[:body.index("\n}\n")]
    for flag, var in [("--passed", "pass_count"), ("--failed", "fail_count"),
                      ("--skipped", "skip_count"), ("--findings", "finding_count")]:
        assert f'{flag} "${var}"' in body, f"{flag} is not wired to ${var}"
    assert "--started-at" in body, "wall clock is not recorded"


def test_worker_still_syntax_checks():
    rc = subprocess.run(["bash", "-n", str(WORKER)], capture_output=True, text=True)
    assert rc.returncode == 0, rc.stderr


@pytest.mark.parametrize("path", [
    SCRIPTS / "regression_shard_record.py",
    REPORT_SCRIPT,
])
def test_modules_compile(path):
    rc = subprocess.run([sys.executable, "-m", "py_compile", str(path)],
                        capture_output=True, text=True)
    assert rc.returncode == 0, rc.stderr
