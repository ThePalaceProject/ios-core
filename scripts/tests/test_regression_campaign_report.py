#!/usr/bin/env python3
"""Pytest for scripts/generate-regression-campaign-report.py (Stage-5 report)."""
import copy
import importlib.util
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURE = SCRIPTS / "tests" / "fixtures" / "regression-findings-sample.csv"

_tspec = importlib.util.spec_from_file_location(
    "regression_triage", SCRIPTS / "regression-triage.py")
triage = importlib.util.module_from_spec(_tspec)
_tspec.loader.exec_module(triage)

_rspec = importlib.util.spec_from_file_location(
    "regression_campaign_report", SCRIPTS / "generate-regression-campaign-report.py")
report = importlib.util.module_from_spec(_rspec)
_rspec.loader.exec_module(report)


@pytest.fixture
def triaged():
    return triage.triage_findings(triage.load_findings(FIXTURE))


@pytest.fixture
def html(triaged):
    return report.render(triaged, run_id="run-test", assets_root=".")


def test_report_is_html_document(html):
    assert html.startswith("<!DOCTYPE html>")
    assert "<title>" in html and "Regression Campaign Report" in html


def test_report_has_coverage_matrix_cells(html):
    # Every device cell present in the fixture appears as a matrix row header.
    for cell in ("C-ipad-on-mac", "C-iphone-26", "C-ipad-26"):
        assert cell in html


def test_report_renders_every_cluster(triaged, html):
    for cid in {r["dedup_cluster"] for r in triaged}:
        assert cid in html


def test_report_shows_taxonomy_classes(html):
    assert "device-divergence" in html
    assert "visual-parity" in html


def test_report_gallery_includes_screenshot_pairs(html):
    # F-003/F-004 carry baseline|candidate pairs -> <img> tags present.
    assert "candidates/lane.png" in html
    assert "baselines/lane.png" in html
    assert "<img" in html


def test_report_evidence_links_present(html):
    assert "crashes/f001_recursive_mutex.ips" in html


def test_report_counts_blockers_and_files(triaged, html):
    blockers = sum(1 for r in triaged if r["severity"] == "blocker")
    assert blockers >= 1
    # the summary card count appears in the document
    assert str(blockers) in html


def test_clusters_ordered_worst_first(triaged):
    groups = report.cluster_groups(triaged)
    ordered = sorted(groups.items(), key=lambda kv: report.cluster_sort_key(kv[1]))
    # the first cluster must contain a blocker (device-divergence)
    first_rows = ordered[0][1]
    assert any(r["severity"] == "blocker" for r in first_rows)


def test_cli_writes_report_file(tmp_path):
    src = tmp_path / "findings.csv"
    src.write_text(FIXTURE.read_text(encoding="utf-8"), encoding="utf-8")
    triage.main(["--csv", str(src)])  # triage first
    out = tmp_path / "report.html"
    rc = report.main(["--csv", str(src), "--output", str(out),
                      "--run-id", "run-x", "--assets-root", "."])
    assert rc == 0
    assert out.exists()
    body = out.read_text(encoding="utf-8")
    assert len(body) > 2000
    assert "run-x" in body


def test_empty_findings_renders_without_crash(tmp_path):
    src = tmp_path / "empty.csv"
    src.write_text(",".join(report.FINDINGS_COLUMNS) + "\n", encoding="utf-8")
    out = tmp_path / "r.html"
    assert report.main(["--csv", str(src), "--output", str(out)]) == 0
    assert "No findings" in out.read_text(encoding="utf-8")


# --- cross-module schema contract (QA-required, #1077 SoD) ------------------

def test_report_columns_match_shared_module_order():
    assert report.FINDINGS_COLUMNS == list(report.rf.FINDINGS_COLUMNS)


def test_report_hard_errors_without_shared_module(tmp_path):
    # Copy ONLY the report script into an isolated dir (no regression_findings.py
    # beside it), empty PYTHONPATH -> `import regression_findings` must hard-error,
    # never silently fall back to a hand-rolled reader.
    iso = tmp_path / "iso"
    iso.mkdir()
    shutil.copy(SCRIPTS / "generate-regression-campaign-report.py",
                iso / "generate-regression-campaign-report.py")
    csv = iso / "f.csv"
    csv.write_text("id,area\nF-1,x\n", encoding="utf-8")
    env = {**os.environ, "PYTHONPATH": ""}
    r = subprocess.run(
        [sys.executable, str(iso / "generate-regression-campaign-report.py"),
         "--csv", str(csv), "--output", str(iso / "r.html")],
        capture_output=True, text=True, env=env, cwd=str(iso))
    assert r.returncode != 0
    assert "ModuleNotFoundError" in r.stderr and "regression_findings" in r.stderr
