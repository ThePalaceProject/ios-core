"""PP-4988: a green test run must not report red because reporting failed.

CI went red on branches whose suites passed, because a step AFTER testing —
uploading the .xcresult artifact, posting the summary comment — failed and took
the job down with it. A board that is red for reasons unrelated to the code
trains everyone to ignore red, and this repo has shipped a broken commit gate
that way before.

Two properties, and the second matters more than the first:

  1. no step whose job is to REPORT may fail the job;
  2. the step that decides pass/fail still can, and still keys on the tests.

A fix that achieved (1) by weakening (2) would be far worse than the flake.
"""

from __future__ import annotations

from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

_WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/unit-testing.yml"

# Steps that exist to publish or archive a result. None of them is a verdict.
_REPORTING_MARKERS = ("Upload", "Post PR", "Deploy Report", "Publish to", "Generate")


# Uploads that carry an INPUT to the verdict rather than a report of it. The
# shards cannot run without the products and plan, and the `build-and-test`
# gate cannot prove every class ran without the shard reports, so a failure to
# upload one of these must fail closed. Every other upload is a report.
_VERDICT_INPUTS = {"Upload test products", "Upload shard plan", "Upload shard report"}


def _jobs() -> dict:
    return yaml.safe_load(_WORKFLOW.read_text())["jobs"]


def _all_steps() -> list[dict]:
    return [s for job in _jobs().values() for s in job.get("steps", [])]


def _test_steps() -> list[dict]:
    """The sharded test job: where the tests run and the per-shard verdict is."""
    return _jobs()["test"]["steps"]


def _is_reporting(step: dict) -> bool:
    return (any(m in step.get("name", "") for m in _REPORTING_MARKERS)
            and step.get("name") not in _VERDICT_INPUTS)


def test_no_reporting_step_can_fail_the_job():
    offenders = [
        s.get("name")
        for s in _all_steps()
        if _is_reporting(s) and not s.get("continue-on-error")
    ]
    assert not offenders, (
        "These steps report results and can still redden the board on their own: "
        f"{offenders}. Failing to archive or publish a result is not a test "
        "failure; add `continue-on-error: true`."
    )


def test_verdict_input_uploads_fail_closed():
    """The opposite direction: an upload the gate depends on must NOT be tolerated.

    If `Upload shard report` could fail quietly, the gate would be checking the
    union of the reports that happened to arrive — a shard that ran nothing and
    uploaded nothing would disappear from the evidence instead of failing it.
    """
    for s in _all_steps():
        if s.get("name") in _VERDICT_INPUTS:
            assert not s.get("continue-on-error"), s.get("name")


def test_the_passfail_gate_is_still_able_to_fail():
    """The whole point of the fix is that REAL failures still stop the board."""
    gate = [s for s in _test_steps() if s.get("name") == "Fail if tests failed"]
    assert gate, "the pass/fail gate step is missing entirely"
    gate = gate[0]
    assert not gate.get("continue-on-error"), (
        "The pass/fail gate must NOT tolerate failure — that would make every run green."
    )
    assert "steps.tests.outcome" in (gate.get("if") or ""), (
        "The gate must key on the TEST step's outcome, not on a reporting step."
    )


def test_the_required_check_waits_for_the_tests_and_not_the_reports():
    """`build-and-test` is the one check branch protection requires.

    It must depend on the build and every shard, so it cannot pass before they
    finish; and it must not depend on `report` or `publish-report`, so a Pages
    or PR-comment failure cannot turn it red.
    """
    gate = _jobs()["build-and-test"]
    needs = set(gate["needs"])
    assert {"changes", "build", "test"} <= needs
    assert not needs & {"report", "publish-report"}
    assert gate.get("if") == "always()", (
        "without always() a failed shard SKIPS the gate, and a skipped required "
        "check reports success")


def test_the_gate_does_not_depend_on_any_reporting_step():
    """A reporting step id must never appear in the gate's condition."""
    steps = _test_steps()
    gate = [s for s in steps if s.get("name") == "Fail if tests failed"][0]
    condition = gate.get("if") or ""
    reporting_ids = {s.get("id") for s in steps if _is_reporting(s) and s.get("id")}
    leaked = [i for i in reporting_ids if i and f"steps.{i}." in condition]
    assert not leaked, (
        f"The pass/fail gate references reporting step(s) {leaked}; a publishing "
        "failure would then be indistinguishable from a test failure again."
    )
