"""Wiring of the sharded Unit Tests workflow (.github/workflows/unit-testing.yml).

prior-art-checked: follows test_ci_reporting_never_reddens_board.py, which reads
the same workflow as YAML.

The scripts have their own tests. These pin how the workflow connects them,
because each connection below is one whose loss would leave CI green while
testing less: a matrix that does not read the plan's shard count, a gate that
does not run the union check, a skipped build that the gate reads as a pass
when tests WERE required, a re-run that cannot replace its own artifacts.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

REPO = Path(__file__).resolve().parents[2]
WF = REPO / ".github/workflows/unit-testing.yml"
DOC = yaml.safe_load(WF.read_text())
# PyYAML reads the bare key `on` as the boolean True.
TRIGGERS = DOC.get("on", DOC.get(True))
JOBS = DOC["jobs"]


def _steps(job):
    return JOBS[job]["steps"]


def _run_text(job):
    return "\n".join(s.get("run", "") for s in _steps(job))


def test_pull_requests_are_not_path_filtered_at_the_workflow_level():
    """A workflow skipped by paths-ignore never reports, so a required
    `build-and-test` would wait forever; the changes job decides instead."""
    pr = TRIGGERS["pull_request"] or {}
    assert "paths-ignore" not in pr and "paths" not in pr


def test_superseded_runs_are_cancelled():
    assert DOC["concurrency"]["cancel-in-progress"] is True
    assert "pull_request.number" in DOC["concurrency"]["group"]


def test_changes_job_runs_the_relevance_script_and_exposes_its_decision():
    assert "scripts/ci-unit-test-relevance.py" in _run_text("changes")
    assert "--github-output" in _run_text("changes")
    assert JOBS["changes"]["outputs"]["run"] == "${{ steps.decide.outputs.run }}"


@pytest.mark.parametrize("job", ["build", "test"])
def test_build_and_test_run_only_when_the_changes_require_it(job):
    assert JOBS[job]["if"] == "needs.changes.outputs.run == 'true'"
    assert "changes" in (JOBS[job]["needs"] if isinstance(JOBS[job]["needs"], list)
                         else [JOBS[job]["needs"]])


def test_the_matrix_is_the_plans_shard_list():
    assert JOBS["test"]["strategy"]["matrix"]["shard"] == "${{ fromJSON(needs.build.outputs.shards) }}"
    assert JOBS["test"]["strategy"]["fail-fast"] is False
    assert JOBS["build"]["outputs"]["shards"] == "${{ steps.plan.outputs.shards }}"


def test_the_build_plans_from_the_enumerated_bundle_with_the_configured_count():
    run = _run_text("build")
    assert "build-for-testing" in run
    assert "-enumerate-tests" in run
    assert "scripts/ci-test-shards.py plan" in run
    assert "UNIT_TEST_SHARDS" in run
    assert isinstance(DOC["env"]["UNIT_TEST_SHARDS"], int) and DOC["env"]["UNIT_TEST_SHARDS"] >= 1


def test_the_shards_use_the_builds_xcode():
    setup = _steps("test")[0]
    assert setup["uses"].startswith("maxim-lobanov/setup-xcode")
    assert setup["with"]["xcode-version"] == "${{ needs.build.outputs.xcode }}"


def test_each_shard_runs_its_plan_slice_without_rebuilding():
    run = _run_text("test")
    assert "scripts/ci-run-test-shard.sh" in run
    assert "xcodebuild build" not in run and "xcodebuild test " not in run


def test_the_gate_runs_the_union_check_and_reads_skips_narrowly():
    gate = JOBS["build-and-test"]
    run = _run_text("build-and-test")
    assert "scripts/ci-test-shards.py verify-union" in run
    # `skipped` is a pass ONLY when the changes job said nothing relevant changed.
    assert re.search(r'if \[ "\$RUN" = "false" \]; then\s+if \[ "\$BUILD" = "skipped" \] && '
                     r'\[ "\$TEST" = "skipped" \]', run)
    assert 'if [ "$TEST" != "success" ]' in run and 'if [ "$BUILD" != "success" ]' in run
    assert gate["if"] == "always()"


def test_per_shard_uploads_can_be_replaced_by_a_rerun():
    """A re-run shard uploads under the same artifact name as the attempt it
    replaces; without overwrite the upload fails and the gate reads the old
    report."""
    for s in _steps("test"):
        if "upload-artifact" in s.get("uses", ""):
            assert s["with"].get("overwrite") is True, s["name"]


def test_the_shard_runner_keeps_retry_scoping():
    """Same guard as test_xcode_test_retry_scoping.py, for the sharded runner."""
    text = (REPO / "scripts/ci-run-test-shard.sh").read_text()
    code = [ln for ln in text.splitlines() if not ln.strip().startswith("#")]
    retry = [ln for ln in code if ln.strip().startswith("RETRY_ITER_ARGS=(-retry")]
    assert retry and "-test-iterations" in retry[0]
    assert not [ln for ln in code if "-test-repetition-relaunch-enabled" in ln]


def _submodule_paths():
    text = (REPO / ".gitmodules").read_text()
    return re.findall(r"^\s*path\s*=\s*(\S+)\s*$", text, flags=re.M)


def _submodules_read_by_tests():
    """Submodule paths that a PalaceTests source names in a string literal,
    e.g. BookmarkSpecConformanceTests reading "mobile-specs/bookmarks" through
    #filePath. Those files exist at run time only if the job checked them out."""
    subs = _submodule_paths()
    found = set()
    for f in (REPO / "PalaceTests").rglob("*.swift"):
        text = f.read_text(errors="ignore")
        for s in subs:
            if re.search(r'"' + re.escape(s) + r'(/[^"]*)?"', text):
                found.add(s)
    return found


def test_the_census_of_submodules_read_by_tests_finds_the_spec_corpus():
    """Guards the census below against matching nothing and passing vacuously."""
    assert "mobile-specs" in _submodules_read_by_tests()


def test_each_shard_checks_out_every_submodule_the_tests_read():
    """The shard checkout has no submodules (the tests run from built products),
    so a test reading a submodule's files through #filePath fails on whichever
    shard it lands on. Run 36787452931: five BookmarkSpecConformanceTests failed
    all three iterations on shard 2 because mobile-specs was absent."""
    run = _run_text("test")
    for sub in sorted(_submodules_read_by_tests()):
        assert re.search(r"git\b.*\bsubmodule update --init\b.*\b" + re.escape(sub) + r"\b", run), sub


def _step(job, name):
    found = [s for s in _steps(job) if s.get("name") == name]
    assert len(found) == 1, f"{job}: expected one step named {name!r}, found {len(found)}"
    return found[0]


def test_the_report_job_checks_that_every_planned_class_ran():
    """Coverage measured over a run that lost classes reads as a coverage drop
    (run 36797084975: three floors 'failed' after a runner hang)."""
    step = next(s for s in _steps("report") if s.get("id") == "completeness")
    assert "scripts/ci-test-shards.py verify-union" in step["run"]
    assert "complete=" in step["run"] and "reason" in step["run"]
    downloads = {s["with"].get("name") or s["with"].get("pattern")
                 for s in _steps("report") if "download-artifact" in s.get("uses", "")}
    assert {"shard-plan", "shard-report-*"} <= downloads


def test_coverage_floors_are_not_evaluated_on_an_incomplete_run_and_say_why():
    step = _step("report", "Enforce Coverage Floors")
    run = step["run"]
    assert "steps.completeness.outputs.complete" in run
    assert "Coverage floors not evaluated" in run and "exit 1" in run, \
        "an incomplete run must report the reason, not skip the floor silently"
    assert "scripts/enforce_coverage_floors.py" in run


def test_runner_failures_are_named_separately_in_the_summary_and_the_pr_comment():
    for name in ("Generate GitHub Step Summary", "Post PR Comment with Results"):
        s = _step("report", name)
        text = s.get("run") or s["with"]["script"]
        assert "steps.parse_results.outputs.runner_failures" in text, name
        assert "steps.completeness.outputs.complete" in text, name
