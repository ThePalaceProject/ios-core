"""tooling-checks.yml must run check-doc-hygiene.sh against each PR's added files.

The checker's fixture test proves its rules; it does not prove CI applies them
to a PR. Run with no flags the checker reads staged files, and a CI checkout has
none, so a step that drops `--base` passes every PR. These tests pin the step,
the history it needs, and then execute the step's own `run:` body in a scratch
repository shaped like a GitHub pull_request checkout (HEAD is a merge of the PR
into its base), asserting it fails on a denied file and passes on a clean one,
including on a re-run after the base has moved past the merge commit.

prior-art-checked: follows test_nodrm_workflow_wiring.py and reuses
scripts/workflow_effective_runs.py; nothing else pins this workflow step.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

_REPO = Path(__file__).resolve().parents[2]
_WORKFLOW = _REPO / ".github/workflows/tooling-checks.yml"
_CHECKER = _REPO / "scripts/check-doc-hygiene.sh"
_INVOCATION = 'bash scripts/check-doc-hygiene.sh --base "origin/${BASE}"'

sys.path.insert(0, str(_REPO / "scripts"))
from workflow_effective_runs import effective_runs  # noqa: E402


def _job_and_step() -> tuple[dict, dict]:
    jobs = yaml.safe_load(_WORKFLOW.read_text())["jobs"]
    hits = [
        (job, step)
        for job in jobs.values()
        for step in job.get("steps") or []
        if _INVOCATION in str(step.get("run", ""))
    ]
    assert len(hits) == 1, f"expected one step running `{_INVOCATION}`, found {len(hits)}"
    return hits[0]


def test_an_effective_step_runs_the_checker_against_the_pr_base():
    runs = effective_runs(_WORKFLOW.read_text())
    assert any(_INVOCATION in line for line in runs), (
        "no step that can fail the build runs check-doc-hygiene.sh with --base; "
        "without it the checker reads the (empty) index and passes every PR"
    )


def test_the_job_fetches_history_and_the_base_before_the_step():
    job, step = _job_and_step()
    assert "BASE" in (job.get("env") or {}), "job does not define BASE"
    steps = job["steps"]
    checkout = next(s for s in steps if str(s.get("uses", "")).startswith("actions/checkout"))
    assert (checkout.get("with") or {}).get("fetch-depth") == 0, (
        "checkout is shallow; origin/${BASE}...HEAD needs a merge base"
    )
    index = steps.index(step)
    assert any(
        "refs/heads/${BASE}" in str(s.get("run", "")) for s in steps[:index]
    ), "the base branch is not fetched before the doc-hygiene step"


def _git(cwd: Path, *args: str) -> str:
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
    }
    return subprocess.run(
        ["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True
    ).stdout


def _pr_checkout(tmp_path: Path, added: list[str]) -> Path:
    """A clone whose HEAD merges a PR adding `added` into develop, base fetched."""
    seed = tmp_path / "seed"
    (seed / "scripts").mkdir(parents=True)
    shutil.copy(_CHECKER, seed / "scripts/check-doc-hygiene.sh")
    (seed / "README.md").write_text("base\n")
    _git(seed, "init", "-q", "-b", "develop")
    _git(seed, "add", "scripts/check-doc-hygiene.sh", "README.md")
    _git(seed, "commit", "-q", "-m", "base")
    _git(seed, "checkout", "-q", "-b", "feature")
    for rel in added:
        (seed / rel).parent.mkdir(parents=True, exist_ok=True)
        (seed / rel).write_text("x\n")
        _git(seed, "add", rel)
    _git(seed, "commit", "-q", "-m", "pr")
    _git(seed, "checkout", "-q", "develop")
    (seed / "later.md").write_text("base moved\n")
    _git(seed, "add", "later.md")
    _git(seed, "commit", "-q", "-m", "base moves on")

    clone = tmp_path / "clone"
    # file:// so a later --depth fetch is honoured as it is against GitHub.
    _git(tmp_path, "clone", "-q", f"file://{seed}", str(clone))
    _git(clone, "fetch", "-q", "origin", "+refs/heads/feature:refs/remotes/origin/feature")
    _git(clone, "checkout", "-q", "--detach", "origin/develop")
    _git(clone, "merge", "-q", "--no-ff", "-m", "merge pr", "origin/feature")
    return clone


def _run_step(cwd: Path, base: str) -> subprocess.CompletedProcess:
    _, step = _job_and_step()
    return subprocess.run(
        ["bash", "-c", step["run"]], cwd=cwd, env={**os.environ, "BASE": base},
        capture_output=True, text=True,
    )


@pytest.mark.parametrize("denied", [".forgeos/swarms/s1/plan.md", "docs/architecture/render.html"])
def test_step_fails_when_the_pr_adds_a_denied_file(tmp_path, denied):
    clone = _pr_checkout(tmp_path, ["docs/architecture/new-adr.md", denied])
    result = _run_step(clone, "develop")
    assert result.returncode == 1, result.stdout + result.stderr
    assert denied in result.stdout


def test_step_passes_when_the_pr_adds_only_legit_docs(tmp_path):
    clone = _pr_checkout(tmp_path, ["docs/architecture/new-adr.md", "Palace/X/README.md"])
    result = _run_step(clone, "develop")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "OK" in result.stdout


def test_step_fails_when_the_base_ref_is_absent(tmp_path):
    clone = _pr_checkout(tmp_path, [".forgeos/swarms/s1/plan.md"])
    result = _run_step(clone, "no-such-branch")
    assert result.returncode != 0
    assert "not fetched" in result.stdout


def _fetches_before_the_step() -> list[str]:
    """`git fetch` lines the job runs before the doc-hygiene step, in order."""
    job, step = _job_and_step()
    lines = []
    for earlier in job["steps"][: job["steps"].index(step)]:
        for line in str(earlier.get("run", "")).splitlines():
            if "git fetch" in line:
                lines.append(line.replace("${{ github.base_ref }}", "${BASE}"))
    return lines


def test_no_shallow_fetch_runs_before_the_step():
    shallow = [line for line in _fetches_before_the_step() if "--depth" in line]
    assert not shallow, (
        f"a --depth fetch runs before doc-hygiene: {shallow}; once the base moves past "
        "the merge commit, that fetch truncates its history and merge-base fails"
    )


def test_step_passes_on_a_rerun_after_the_base_moves_past_the_merge_commit(tmp_path):
    clone = _pr_checkout(tmp_path, ["docs/architecture/new-adr.md"])
    seed = tmp_path / "seed"
    (seed / "after-merge.md").write_text("base moved again\n")
    _git(seed, "add", "after-merge.md")
    _git(seed, "commit", "-q", "-m", "base moves past the merge commit")

    fetches = subprocess.run(
        ["bash", "-c", "set -euo pipefail\n" + "\n".join(_fetches_before_the_step())],
        cwd=clone, env={**os.environ, "BASE": "develop"}, capture_output=True, text=True,
    )
    assert fetches.returncode == 0, fetches.stderr
    result = _run_step(clone, "develop")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "OK" in result.stdout


def test_step_fails_when_head_shares_no_history_with_the_base(tmp_path):
    clone = _pr_checkout(tmp_path, ["docs/architecture/new-adr.md"])
    _git(clone, "checkout", "-q", "--orphan", "unrelated")
    _git(clone, "commit", "-q", "-m", "unrelated root")
    result = _run_step(clone, "develop")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "shares no history" in result.stdout
