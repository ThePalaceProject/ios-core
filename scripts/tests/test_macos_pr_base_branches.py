"""Pull requests into a feature/** branch run no macOS workflow; every other base does.

Multi-PR work lands its sub-task PRs on a feature branch, and the feature
branch's PR into develop runs the macOS CI once for all of them
(docs/architecture/feature-branch-workflow.md). PRs into any other base
(develop, main, release/**, hotfix/**, and work branches such as feat/* or
fix/*) keep their macOS runs. Workflows that only fire on `closed` (the upload
and release jobs) are out of scope: they already filter on their base.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

_WORKFLOWS = Path(__file__).resolve().parents[2] / ".github/workflows"

# Ledger has filtered to [main, develop] since before the feature-branch rule.
_NARROWER_BASES = {"ledger.yml"}
_KEPT_BASES = ["develop", "main", "release/3.5.0", "hotfix/3.4.1-x", "feat/x", "fix/PP-1-y"]


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


def _glob(pattern: str) -> re.Pattern:
    # GitHub filter globs: `**` crosses `/`, `*` does not.
    out = ""
    for part in re.split(r"(\*\*|\*)", pattern):
        out += {"**": ".*", "*": "[^/]*"}.get(part, re.escape(part))
    return re.compile(out + r"\Z")


def _runs_for_base(pr: dict, base: str) -> bool:
    if "branches" in pr:
        return any(_glob(p).match(base) for p in pr["branches"])
    if "branches-ignore" in pr:
        return not any(_glob(p).match(base) for p in pr["branches-ignore"])
    return True


def test_the_scan_finds_the_known_macos_pr_workflows():
    names = {name for name, _ in _macos_pr_workflows()}
    assert {"unit-testing.yml", "ui-journeys.yml", "tsan.yml", "non-drm-build.yml"} <= names


@pytest.mark.parametrize("name,pr", _macos_pr_workflows())
def test_a_pr_into_a_feature_branch_does_not_run_it(name, pr):
    assert not _runs_for_base(pr, "feature/PP-1-x"), f"{name}: a PR into a feature branch runs it"


@pytest.mark.parametrize("name,pr", _macos_pr_workflows())
def test_a_pr_into_any_other_base_still_runs_it(name, pr):
    bases = ["develop", "main"] if name in _NARROWER_BASES else _KEPT_BASES
    dropped = [b for b in bases if not _runs_for_base(pr, b)]
    assert not dropped, f"{name}: a PR into {dropped} would not run it"
