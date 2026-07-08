#!/usr/bin/env python3
"""Pytest for scripts/rc-report.py (Stage-5 findings.csv -> report.html).

Tests behaviour, not structure: the gating split, the demote-not-hide rule, the
empty-run robustness, and the ForgeOS changeset-per-gating-regression emission.
These are the mutation targets — flip the gating predicate or hide a non-gating
finding and one of these reds.
"""
import importlib.util
import shutil
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURE = SCRIPTS / "tests" / "fixtures" / "rc-report-sample.csv"

# Load the hyphenated module by path (same idiom as the sibling tests).
_spec = importlib.util.spec_from_file_location("rc_report", SCRIPTS / "rc-report.py")
rcr = importlib.util.module_from_spec(_spec)
sys.modules["rc_report"] = rcr
_spec.loader.exec_module(rcr)


def _run_dir(tmp_path: Path, *, with_forge: bool = False) -> Path:
    """Materialize a run-dir from the fixture. If with_forge, nest it under a
    fake repo carrying .forgeos/changesets so changeset emission has a target."""
    root = tmp_path / "repo" if with_forge else tmp_path
    if with_forge:
        (root / ".forgeos" / "changesets").mkdir(parents=True)
    run = root / ".regression-runs" / "rc-test"
    run.mkdir(parents=True)
    shutil.copy(FIXTURE, run / "findings.csv")
    return run


# --- gating predicate -------------------------------------------------------

def test_gating_requires_verified_and_file_jira():
    assert rcr.is_gating(
        {"verified": "true", "disposition": "file-jira"}) is True
    # unverified file-jira is NOT gating (must clear the hermetic re-verify gate)
    assert rcr.is_gating(
        {"verified": "false", "disposition": "file-jira"}) is False
    # verified but not file-jira is NOT gating
    assert rcr.is_gating(
        {"verified": "true", "disposition": "needs-verify"}) is False
    assert rcr.is_gating(
        {"verified": "true", "disposition": "non-gating-known-fragile"}) is False


def test_only_two_fixture_rows_are_gating(tmp_path):
    run = _run_dir(tmp_path)
    rows = rcr.rf.read_findings(str(run / "findings.csv"))
    gating = [r for r in rows if rcr.is_gating(r)]
    assert {r["id"] for r in gating} == {
        "catalog-C-iphone-26-lane-render-000",
        "audiobook-C-iphone-26-crash-000",
    }


# --- demote != hide: every finding still appears -----------------------------

def test_all_findings_shown_including_non_gating(tmp_path):
    run = _run_dir(tmp_path)
    rcr.generate(run)
    html = (run / "report.html").read_text()
    for fid in (
        "catalog-C-iphone-26-lane-render-000",
        "audiobook-C-iphone-26-crash-000",
        "auth-C-iphone-26-picker-fragile-000",   # non-gating-known-fragile
        "reader-C-iphone-26-resume-000",          # needs-verify
        "token-C-iphone-26-flake-000",            # ticket-as-flake
    ):
        assert fid in html, f"{fid} was hidden — demote must not hide"


def test_gating_and_nongating_sections_both_render(tmp_path):
    run = _run_dir(tmp_path)
    rcr.generate(run)
    html = (run / "report.html").read_text()
    assert "real regressions (block the tag)" in html
    assert "do not block" in html
    # exactly the 2 gating findings carry the gating card class
    assert html.count('class="f gating"') >= 2


# --- screenshot pair surfaced ------------------------------------------------

def test_screenshot_pair_emits_images(tmp_path):
    run = _run_dir(tmp_path)
    rcr.generate(run)
    html = (run / "report.html").read_text()
    assert "baselines/lane.png" in html
    assert "candidates/lane.png" in html
    assert "<figcaption>baseline</figcaption>" in html


# --- empty / missing robustness ---------------------------------------------

def test_missing_findings_csv_is_valid_empty_report(tmp_path):
    run = tmp_path / "empty-run"
    run.mkdir()
    out = rcr.generate(run)          # no findings.csv at all
    assert out.exists()
    assert "Empty run" in out.read_text()


def test_header_only_findings_csv_is_empty_report(tmp_path):
    run = tmp_path / "hdr-run"
    run.mkdir()
    (run / "findings.csv").write_text(",".join(rcr.rf.FINDINGS_COLUMNS) + "\n")
    out = rcr.generate(run)
    assert "Empty run" in out.read_text()


# --- ForgeOS changeset stub emission ----------------------------------------

def test_changeset_stub_per_gating_regression(tmp_path):
    run = _run_dir(tmp_path, with_forge=True)
    rcr.generate(run)
    cs_dir = tmp_path / "repo" / ".forgeos" / "changesets"
    stubs = sorted(p.parent.name for p in cs_dir.rglob("fix-contract.md"))
    # one stub per gating finding (2), none for the non-gating 3
    assert len(stubs) == 2
    assert all(s.startswith("rc-regression-") for s in stubs)


def test_no_changeset_when_outside_forge_repo(tmp_path):
    # run-dir with no .forgeos ancestor: emission is skipped, no crash.
    run = _run_dir(tmp_path, with_forge=False)
    cs = rcr.emit_changesets(run, [r for r in rcr.rf.read_findings(
        str(run / "findings.csv")) if rcr.is_gating(r)])
    assert cs == []


def test_changeset_stub_has_finding_evidence(tmp_path):
    run = _run_dir(tmp_path, with_forge=True)
    rcr.generate(run)
    stub = (tmp_path / "repo" / ".forgeos" / "changesets"
            / "rc-regression-audiobook-c-iphone-26-crash-000" / "fix-contract.md")
    body = stub.read_text()
    assert "audiobook-C-iphone-26-crash-000" in body
    assert "logs/crash.ips" in body            # evidence carried into the stub
    assert "/forge-review" in body             # SoD handoff instruction


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
