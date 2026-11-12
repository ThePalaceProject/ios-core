"""Pull requests into a feature/** branch run no macOS workflow.

Multi-PR work lands its sub-task PRs on a feature branch, and the feature
branch's PR into develop runs the macOS CI once for all of them
(docs/architecture/feature-branch-workflow.md). Every workflow that has a macOS
job and a `pull_request` trigger must therefore list its bases, and the list
must cover develop and leave out feature branches. Workflows that only fire on
`closed` (the upload and release jobs) are out of scope: they already filter on
their base.
"""

from __future__ import annotations

import fnmatch
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

_WORKFLOWS = Path(__file__).resolve().parents[2] / ".github/workflows"
_ALLOWED = {"develop", "main", "release/**", "hotfix/**", "beta"}


def _triggers(doc):
    # PyYAML reads the bare key `on` as the boolean True.
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {k: None for k in on}
    return on or {}


def _has_macos_job(doc) -> bool:
    return any(
        "macos" in str(job.get("runs-on", "")) for job in (doc.get("jobs") or {}).values()
    )


def _macos_pr_workflows():
    found = []
    for path in sorted(_WORKFLOWS.glob("*.yml")):
        doc = yaml.safe_load(path.read_text())
        triggers = _triggers(doc)
        if "pull_request" not in triggers or not _has_macos_job(doc):
            continue
        pr = triggers["pull_request"] or {}
        if pr.get("types") == ["closed"]:
            continue
        found.append((path.name, pr))
    return found


def _matches(branch: str, patterns) -> bool:
    # GitHub's `**` matches across `/`; fnmatch's `*` already does.
    return any(fnmatch.fnmatchcase(branch, p) for p in patterns)


def test_the_scan_finds_the_known_macos_pr_workflows():
    names = {name for name, _ in _macos_pr_workflows()}
    assert {"unit-testing.yml", "ui-journeys.yml", "tsan.yml", "non-drm-build.yml"} <= names


@pytest.mark.parametrize("name,pr", _macos_pr_workflows())
def test_macos_pr_workflow_lists_its_bases(name, pr):
    branches = pr.get("branches")
    assert branches, f"{name}: pull_request has no `branches`, so a PR into feature/** runs it"
    assert set(branches) <= _ALLOWED, f"{name}: unexpected bases {set(branches) - _ALLOWED}"


@pytest.mark.parametrize("name,pr", _macos_pr_workflows())
def test_macos_pr_workflow_runs_for_develop_and_skips_feature_branches(name, pr):
    branches = pr.get("branches") or ["**"]
    assert _matches("develop", branches), f"{name}: a PR into develop would not run it"
    assert not _matches("feature/PP-1-x", branches), f"{name}: a PR into a feature branch runs it"
