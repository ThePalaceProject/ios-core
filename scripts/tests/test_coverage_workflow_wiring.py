"""unit-testing.yml carries package coverage from collection to the report, and
cannot mask a coverage failure as a measurement.

prior-art-checked: extends the workflow tests in test_unit_test_workflow_sharding.py.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
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


def test_floor_step_and_report_job_can_fail():
    """The floors block only if their failure fails the report job."""
    sys.path.insert(0, str(REPO / "scripts"))
    from workflow_effective_runs import effective_runs
    runs = effective_runs(WORKFLOW.read_text())
    assert any("scripts/enforce_coverage_floors.py" in r for r in runs)
    assert "continue-on-error" not in _step("report", "Enforce Coverage Floors")
    assert "continue-on-error" not in _jobs()["report"]
    assert _jobs()["report"]["outputs"]["coverage_floors"] == "${{ steps.coverage_gate.outcome }}"


def test_archive_and_publish_still_run_when_the_floors_fail():
    """A floor failure is when the report matters most; it must still be kept."""
    for name in ("Upload Test Results", "Upload Snapshot Failures"):
        assert _step("report", name)["if"].startswith("always() && "), name
    cond = _jobs()["publish-report"]["if"]
    assert "needs.report.result == 'failure'" in cond and "needs.report.result == 'success'" in cond


def _evaluate(tmp_path, **results):
    step = next(s for s in _jobs()["build-and-test"]["steps"] if s.get("id") == "eval")
    env_map = {"CHANGES": "changes", "RUN": "run", "BUILD": "build", "TEST": "test",
               "REPORT": "report", "FLOORS": "floors", "FLOORS_STATUS": "floors_status"}
    assert set(step["env"]) == set(env_map)
    out = tmp_path / "out"
    out.write_text("")
    env = {"PATH": "/usr/bin:/bin", "GITHUB_OUTPUT": str(out)}
    env.update({k: results.get(v, "") for k, v in env_map.items()})
    r = subprocess.run(["bash", "-c", step["run"]], env=env, capture_output=True, text=True)
    return r.returncode, out.read_text(), r.stdout


GREEN = dict(changes="success", run="true", build="success", test="success",
             report="success", floors="success", floors_status="evaluated")


def test_gate_env_reads_the_report_job():
    env = next(s for s in _jobs()["build-and-test"]["steps"] if s.get("id") == "eval")["env"]
    assert env["REPORT"] == "${{ needs.report.result }}"
    assert env["FLOORS"] == "${{ needs.report.outputs.coverage_floors }}"
    assert env["FLOORS_STATUS"] == "${{ needs.report.outputs.coverage_floors_status }}"
    assert _jobs()["report"]["outputs"]["coverage_floors_status"] == \
        "${{ steps.coverage_gate.outputs.floors_status }}"
    assert "report" in _jobs()["build-and-test"]["needs"]


def test_gate_passes_a_full_green_run(tmp_path):
    rc, out, _ = _evaluate(tmp_path, **GREEN)
    assert rc == 0 and "verify=true" in out


@pytest.mark.parametrize("override", [
    {"floors": "failure"},                        # violation (exit 1) or incomplete (exit 3)
    {"floors": "", "report": "failure"},           # report died before the floor step
    {"floors": "", "report": "cancelled"},
    {"report": "failure"},                         # another report step failed
    {"report": "skipped", "floors": ""},           # run required but no report
    {"floors": "skipped"},
])
def test_gate_fails_when_the_floors_or_report_did_not_pass(tmp_path, override):
    rc, out, _ = _evaluate(tmp_path, **{**GREEN, **override})
    assert rc == 1 and "verify=true" not in out


def test_gate_passes_a_docs_only_skip(tmp_path):
    rc, out, _ = _evaluate(tmp_path, changes="success", run="false", build="skipped",
                           test="skipped", report="skipped")
    assert rc == 0 and "verify=false" in out


def test_gate_rejects_a_skip_where_report_still_ran(tmp_path):
    rc, _, _ = _evaluate(tmp_path, changes="success", run="false", build="skipped",
                         test="skipped", report="failure")
    assert rc == 1


def _run_floor_step(tmp_path, complete, enforcer_rc):
    """Runs the floor step's script with python3 stubbed to exit `enforcer_rc`.

    -> (exit status, step outputs, the enforcer's argv)."""
    step = _step("report", "Enforce Coverage Floors")
    stub = tmp_path / "bin"
    stub.mkdir()
    argv = tmp_path / "argv"
    (stub / "python3").write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{argv}"\nexit {enforcer_rc}\n')
    (stub / "python3").chmod(0o755)
    out = tmp_path / "step-output"
    out.write_text("")
    env = {"PATH": f"{stub}:/usr/bin:/bin", "COMPLETE": complete,
           "REASON": "shard 2 lost classes", "GITHUB_OUTPUT": str(out)}
    rc = subprocess.run(["bash", "-e", "-c", step["run"]], env=env,
                        capture_output=True, text=True).returncode
    return rc, out.read_text(), argv.read_text().splitlines() if argv.exists() else []


@pytest.mark.parametrize("complete,enforcer_rc,expected,status", [
    ("true", 0, 0, "evaluated"),
    ("true", 1, 1, "evaluated"),    # floor violation
    ("true", 3, 3, "evaluated"),    # the enforcer refused to compare without the flag
    ("true", 2, 2, "evaluated"),    # input error
    ("true", 4, 0, "abstained"),    # incomplete coverage: the floors abstain
    ("false", 4, 0, "abstained"),
    ("", 4, 0, "abstained"),
])
def test_floor_step_exit_status(tmp_path, complete, enforcer_rc, expected, status):
    rc, outputs, _ = _run_floor_step(tmp_path, complete, enforcer_rc)
    assert rc == expected
    assert f"floors_status={status}" in outputs


@pytest.mark.parametrize("complete", ["false", ""])
def test_floor_step_hands_the_enforcer_the_completeness_reason(tmp_path, complete):
    """The floors abstain on the shard verdict as well as on the coverage data's
    own status, so the reason the gate reports has to reach the enforcer."""
    _, _, argv = _run_floor_step(tmp_path, complete, 4)
    assert "--abstain-on-incomplete" in argv
    assert "--incomplete-reason" in argv
    assert any("shard 2 lost classes" in a for a in argv)


def test_floor_step_does_not_claim_incompleteness_on_a_complete_run(tmp_path):
    """A --incomplete-reason on a complete run would abstain over nothing."""
    _, _, argv = _run_floor_step(tmp_path, "true", 0)
    assert "--incomplete-reason" not in argv


def test_gate_fails_an_abstain_the_shards_do_not_explain(tmp_path):
    """Abstaining is not a pass: with every shard green and no coverage to
    compare, nothing else in the run has failed, so the gate must."""
    rc, out, _ = _evaluate(tmp_path, **{**GREEN, "floors_status": "abstained"})
    assert rc == 1 and "verify=true" not in out


def test_gate_fails_a_dead_shard_once_without_the_floors_also_failing(tmp_path):
    """The point of the abstain: one infrastructure fault, one explanation. The
    gate names the shard, and the floors' own outcome stays green."""
    rc, out, log = _evaluate(tmp_path, **{**GREEN, "test": "failure",
                                          "floors_status": "abstained"})
    assert rc == 1 and "verify=true" not in out
    assert "one or more test shards: failure" in log
    assert "floors" not in log.split("::error::")[-1]


def test_gate_fails_when_report_was_cancelled_after_the_floors_passed(tmp_path):
    rc, out, _ = _evaluate(tmp_path, **{**GREEN, "report": "cancelled"})
    assert rc == 1 and "verify=true" not in out


@pytest.mark.parametrize("build,test", [("success", "skipped"), ("skipped", "success")])
def test_gate_rejects_a_skip_where_build_or_test_still_ran(tmp_path, build, test):
    rc, _, _ = _evaluate(tmp_path, changes="success", run="false", build=build,
                         test=test, report="skipped")
    assert rc == 1


# Report steps whose failure may fail the job and so the required check. Every
# other step reports and must be continue-on-error (PP-4988).
_REPORT_STEPS_THAT_MAY_FAIL = {
    "Set up Xcode", "Checkout", "Cache Test History", "Find Test Results",
    "Parse Test Results", "Compare with History", "Save to History",
    "Parse Code Coverage", "Enforce Coverage Floors", "Process Snapshot Failures",
    "Report URL", "Note if results could not be archived",
}


def test_only_listed_report_steps_can_fail_the_required_check():
    can_fail = {s.get("name") for s in _jobs()["report"]["steps"] if not s.get("continue-on-error")}
    assert can_fail == _REPORT_STEPS_THAT_MAY_FAIL


def test_every_floor_scope_in_the_floors_file_is_declared_blocking_or_advisory():
    """A new scope in coverage-floors.json must be placed on one side on purpose;
    test_enforce_coverage_floors.py checks that ADVISORY_SCOPES drives behaviour."""
    sys.path.insert(0, str(REPO / "scripts"))
    import enforce_coverage_floors as ecf
    floors = json.loads((REPO / "scripts" / "coverage-floors.json").read_text())
    scopes = {k for k in floors if not k.startswith("_") and k != "unmeasured"}
    assert scopes == {"overall", "modules"} | set(ecf.ADVISORY_SCOPES)
    assert not {"overall", "modules"} & set(ecf.ADVISORY_SCOPES)


def test_floor_step_compares_the_recorded_floors():
    run = _step("report", "Enforce Coverage Floors")["run"]
    assert "--floors scripts/coverage-floors.json" in run
    assert "--baseline-only" not in run and "--write-baseline" not in run
