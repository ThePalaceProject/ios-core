"""The Audiobook Toolkit Tests workflow must run the toolkit's suite and be able to fail.

PalaceAudiobookToolkitTests is not in the Palace scheme, so this workflow is
the only place CI executes it from this repo. Three properties, parsed as YAML:

  1. it triggers on a change to the submodule pin and to every repo file the
     job reads, so a change that breaks the job also runs it;
  2. it checks out the toolkit submodule (and only that one);
  3. the result bundle the test step writes is the one the gate step reads,
     and the gate runs after the tests. xcodebuild exits 0 when a scheme
     selects no tests, so without the gate an empty run is green;
  4. AudioEngine (Findaway's licensed SDK) is fetched only in same-repo runs,
     and a fork PR gets a job that says the tests were skipped.

prior-art-checked: this pins a public GitHub workflow; the pattern follows
test_nodrm_workflow_wiring.py, and the test runs on a clean ubuntu runner.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

_REPO = Path(__file__).resolve().parents[2]
_WORKFLOW_REL = ".github/workflows/audiobook-toolkit-tests.yml"
_WORKFLOW = _REPO / _WORKFLOW_REL
_GATE = "scripts/xcresult_summary.py"


def _doc() -> dict:
    return yaml.safe_load(_WORKFLOW.read_text())


def _triggers() -> dict:
    doc = _doc()
    on = doc.get("on", doc.get(True))  # PyYAML reads a bare `on:` as True.
    assert isinstance(on, dict), f"unexpected `on:` shape: {on!r}"
    return on


_TEST_JOB = "toolkit-tests"
_FORK_JOB = "toolkit-tests-skipped-on-fork"
_REPO_NAME = "ThePalaceProject/ios-core"


def _jobs() -> dict:
    jobs = _doc()["jobs"]
    assert set(jobs) == {_TEST_JOB, _FORK_JOB}, f"unexpected jobs: {list(jobs)}"
    return jobs


def _steps() -> list[dict]:
    return _jobs()[_TEST_JOB]["steps"]


def _evaluate(condition: str, event: str, head_repo: str | None) -> bool:
    """Evaluate a job `if:` for one event, over the few contexts it may use."""
    expr = condition.strip()
    if expr.startswith("${{") and expr.endswith("}}"):
        expr = expr[3:-2]
    contexts = {
        "github.event.pull_request.head.repo.full_name": repr(head_repo),
        "github.event_name": repr(event),
        "github.repository": repr(_REPO_NAME),
    }
    for name, value in contexts.items():
        expr = expr.replace(name, value)
    expr = expr.replace("||", " or ").replace("&&", " and ")
    leftover = re.sub(r"'[^']*'|None|==|!=|\bor\b|\band\b|[()\s]", "", expr)
    assert not leftover, f"condition uses something this test cannot evaluate: {leftover!r}"
    return bool(eval(expr, {"__builtins__": {}}))  # noqa: S307 - vetted above


# (event, head repo of the PR or None, is the run trusted)
_RUNS = [
    ("pull_request", _REPO_NAME, True),
    ("pull_request", "someone/ios-core", False),
    ("workflow_dispatch", None, True),
]


def _index_running(fragment: str) -> int:
    hits = [i for i, s in enumerate(_steps()) if fragment in str(s.get("run", ""))]
    assert len(hits) == 1, f"`{fragment}` is run by {len(hits)} steps; expected one"
    return hits[0]


def _result_bundle(run: str) -> str:
    m = re.search(r"-resultBundlePath\s+\"?([^\"\s]+)\"?", run)
    assert m, "the test step must write a result bundle with -resultBundlePath"
    return m.group(1)


# --- 1. trigger -------------------------------------------------------------

def test_pull_request_trigger_includes_the_submodule_pin():
    paths = (_triggers()["pull_request"] or {}).get("paths") or []
    assert "ios-audiobooktoolkit" in paths, (
        f"pull_request.paths lacks the submodule path; a pin bump would not run "
        f"the toolkit suite: {paths}"
    )
    assert _WORKFLOW_REL in paths


def test_every_repo_script_the_job_runs_is_a_trigger_path():
    paths = (_triggers()["pull_request"] or {}).get("paths") or []
    runs = "\n".join(str(s.get("run", "")) for s in _steps())
    scripts = sorted(set(re.findall(r"scripts/[\w.-]+", runs)))
    assert scripts, "expected the job to run at least one repo script"
    for script in scripts:
        assert script in paths, f"{script} is run by the job but is not in pull_request.paths"
        assert (_REPO / script).is_file(), f"{script} is run by the job but does not exist"


def test_workflow_is_manually_dispatchable():
    assert "workflow_dispatch" in _triggers()


# --- 2. checkout ------------------------------------------------------------

def test_only_the_toolkit_submodule_is_checked_out():
    checkouts = [s for s in _steps() if str(s.get("uses", "")).startswith("actions/checkout@")]
    assert len(checkouts) == 1
    # The other submodules are private DRM repos; fetching them would need the
    # CI token and would fail on fork PRs for no benefit.
    assert (checkouts[0].get("with") or {}).get("submodules") is False
    _index_running("git submodule update --init ios-audiobooktoolkit")


# --- 3. test step -> gate ---------------------------------------------------

def test_gate_reads_the_bundle_the_test_step_writes_and_runs_after_it():
    steps = _steps()
    test_idx = _index_running("xcodebuild test")
    gate_idx = _index_running(_GATE)
    assert gate_idx > test_idx, "the gate must follow the test step"
    bundle = _result_bundle(steps[test_idx]["run"])
    gate_run = steps[gate_idx]["run"]
    assert "--mode gate" in gate_run
    assert bundle in gate_run, f"the gate does not read {bundle}: {gate_run}"


def test_gate_is_not_skipped_after_a_passing_test_step():
    condition = str(_steps()[_index_running(_GATE)].get("if", ""))
    # A green test step is exactly the case the gate exists for (an empty run
    # exits 0), so no condition may skip it then.
    assert "failure()" not in condition
    assert "!success()" not in condition


def test_test_step_runs_the_whole_toolkit_scheme():
    run = _steps()[_index_running("xcodebuild test")]["run"]
    assert "ios-audiobooktoolkit/PalaceAudiobookToolkit.xcodeproj" in run
    assert re.search(r"-scheme\s+PalaceAudiobookToolkit\b", run)
    assert "-only-testing" not in run, "the job runs the whole toolkit suite, not a subset"


# --- 4. AudioEngine stays out of fork PRs -----------------------------------

@pytest.mark.parametrize("event,head_repo,trusted", _RUNS)
def test_tests_and_audioengine_fetch_run_only_in_same_repo_runs(event, head_repo, trusted):
    condition = str(_jobs()[_TEST_JOB].get("if", ""))
    assert condition, "the toolkit-tests job has no `if:`; fork PRs would fetch AudioEngine"
    assert _evaluate(condition, event, head_repo) is trusted
    _index_running("scripts/fetch-audioengine.sh")


@pytest.mark.parametrize("event,head_repo,trusted", _RUNS)
def test_fork_pr_gets_a_visible_skip_and_nothing_else(event, head_repo, trusted):
    job = _jobs()[_FORK_JOB]
    assert _evaluate(str(job.get("if", "")), event, head_repo) is (not trusted)
    runs = "\n".join(str(s.get("run", "")) for s in job["steps"])
    assert "::notice::toolkit tests skipped on fork PRs" in runs
    assert "fetch-audioengine" not in runs and "xcodebuild" not in runs
