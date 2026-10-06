"""The UI Journeys workflow runs the fixture journeys, and only those.

The unit-test workflow measures coverage with the Palace scheme; this lane must
not touch that run, so it uses its own scheme. Pinned here, parsed as YAML:

  1. it runs on pull requests that change the app, the journeys or the project;
  2. it tests the PalaceUITests scheme with the ad-hoc signing the docs give;
  3. its verdict is xcodebuild's exit status, not the status of a pipe;
  4. uploading the result bundle cannot fail the job.

prior-art-checked: this pins a public GitHub workflow, like
test_nodrm_workflow_wiring.py; no harness capability inspects repository
workflows, and tooling-checks runs this on a clean runner without the harness.
"""

from __future__ import annotations

from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

_REPO = Path(__file__).resolve().parents[2]
_WORKFLOW = _REPO / ".github/workflows/ui-journeys.yml"


def _doc() -> dict:
    return yaml.safe_load(_WORKFLOW.read_text())


def _steps() -> list[dict]:
    return _doc()["jobs"]["journeys"]["steps"]


def _step(name: str) -> dict:
    matches = [s for s in _steps() if s.get("name") == name]
    assert len(matches) == 1, f"expected one step named {name!r}"
    return matches[0]


def test_runs_on_pull_requests_that_touch_the_app_or_the_journeys():
    doc = _doc()
    on = doc.get("on", doc.get(True))
    paths = on["pull_request"]["paths"]
    for required in ("Palace/**", "PalaceUITests/**", "Palace.xcodeproj/**"):
        assert required in paths, f"{required} missing from the path filter"
    assert "workflow_dispatch" in on


_SIGNING = ("CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", 'DEVELOPMENT_TEAM=""')


def test_tests_the_ui_scheme_not_the_unit_test_scheme():
    run = _step("Build and run the journeys")["run"]
    assert "-scheme PalaceUITests" in run
    assert "-scheme Palace " not in run and "-enableCodeCoverage" not in run


def test_signing_matches_the_documented_command():
    run = _step("Build and run the journeys")["run"]
    docs = (_REPO / "docs/Testing/UI_JOURNEYS.md").read_text()
    for setting in _SIGNING:
        assert setting in run, f"{setting} missing from the workflow"
        assert setting in docs, f"{setting} missing from the documented command"


def test_verdict_is_xcodebuilds_exit_status_and_the_summary_is_written_first():
    """GitHub runs `shell: bash` with -e and pipefail, so without `set +e` a
    failing xcodebuild ends the step before the status or summary lines run."""
    lines = [ln.strip() for ln in _step("Build and run the journeys")["run"].splitlines()]
    xcodebuild = next(i for i, ln in enumerate(lines) if ln.startswith("xcodebuild test"))
    assert "set +e" in lines[:xcodebuild]
    tee = next(ln for ln in lines[xcodebuild:] if "| tee ui-journeys.log" in ln)
    assert "||" not in tee, "a fallback on the pipeline would turn failures into passes"
    assert "status=${PIPESTATUS[0]}" in lines
    assert lines[-1] == 'exit "$status"'


def test_a_run_with_no_passing_journey_fails():
    """`xcodebuild test` that runs nothing still prints TEST SUCCEEDED."""
    run = _step("Build and run the journeys")["run"]
    assert 'grep -cE "^Test Case .*passed" ui-journeys.log' in run
    assert "no journey ran" in run


def test_uploading_results_cannot_fail_the_job():
    upload = _step("Upload journey results")
    assert upload.get("continue-on-error") is True
    assert upload.get("if") == "failure()"
