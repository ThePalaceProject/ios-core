"""unit-testing.yml carries package coverage from collection to the report, and
cannot mask a coverage failure as a measurement.

prior-art-checked: extends the workflow tests in test_unit_test_workflow_sharding.py.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

REPO = Path(__file__).resolve().parents[2]
WORKFLOW = REPO / ".github" / "workflows" / "unit-testing.yml"


def _jobs():
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]


def _step(job, name):
    return next(s for s in _jobs()[job]["steps"] if s.get("name") == name)


def _swift_test_steps():
    return [s for s in _jobs()["test"]["steps"] if "swift test" in (s.get("run") or "")
            and "--show-codecov-path" not in s["run"]]


def _loop_packages(run):
    m = re.search(r"for pkg in ([A-Za-z ]+); do", run)
    assert m, run
    return set(m.group(1).split())


def test_every_package_test_step_collects_coverage():
    steps = _swift_test_steps()
    assert len(steps) >= 5
    for s in steps:
        assert "--enable-code-coverage" in s["run"], s["name"]


def test_package_lists_agree_with_each_other_and_the_floors():
    """The host package list is written in the test steps, the collect loop and
    the report's expectations; a package added to one and not the others would
    drop its host coverage without a sign."""
    tested = {re.search(r"--package-path Palace/Packages/(\w+)", s["run"]).group(1)
              for s in _swift_test_steps()}
    collected = _loop_packages(_step("test", "Collect package coverage")["run"])
    expected = _loop_packages(_step("report", "Parse Code Coverage")["run"])
    floors = set(json.loads((REPO / "scripts" / "coverage-floors.json").read_text())["host_packages"])
    assert tested == collected == expected == floors


def test_package_coverage_is_uploaded_by_the_test_job_and_downloaded_by_the_report():
    up = _step("test", "Upload package coverage")
    assert up["with"]["name"] == "package-coverage"
    down = _step("report", "Download package coverage")
    assert down["with"]["name"] == "package-coverage"
    assert down["with"]["path"] == "package-coverage"
    assert "--host-package-dir package-coverage" in _step("report", "Parse Code Coverage")["run"]


def test_build_rewrites_coverage_metadata_before_packaging_the_products():
    names = [s.get("name") for s in _jobs()["build"]["steps"]]
    i = names.index("Point coverage metadata at the package binaries")
    assert i < names.index("Package test products")
    assert "scripts/ci-xctestrun-package-coverage.py" in _jobs()["build"]["steps"][i]["run"]


def test_coverage_report_failure_is_not_masked():
    run = _step("report", "Parse Code Coverage")["run"]
    assert "coverage-report.py" in run
    assert "|| true" not in run
    assert "--expect-local-packages" in run
    assert "--incomplete-reason" in run and "steps.completeness" not in run  # read via env
    assert _step("report", "Parse Code Coverage")["env"]["COMPLETE"] == "${{ steps.completeness.outputs.complete }}"


def test_floor_step_runs_on_every_report_and_propagates_incomplete():
    step = _step("report", "Enforce Coverage Floors")
    assert step["if"] == "always()"
    assert 'exit "$RC"' in step["run"]
    assert "Coverage incomplete" in step["run"]


def test_summary_and_comment_show_incomplete_and_the_package_table():
    summary = _step("report", "Generate GitHub Step Summary")["run"]
    comment = _step("report", "Post PR Comment with Results")["with"]["script"]
    for text in (summary, comment):
        assert "steps.coverage.outputs.coverage_status" in text
        assert "steps.coverage.outputs.coverage_packages" in text
        assert "INCOMPLETE" in text
