"""unit-testing.yml publishes test reports to GitHub Pages without the site
growing past the 1 GB Pages limit.

Every report since the first was kept on gh-pages until the site reached
1.15 GB, and every deploy from 2026-10-01 on failed. The assemble step runs
here against a local gh-pages branch.

prior-art-checked: extends the workflow tests in test_coverage_workflow_wiring.py.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

REPO = Path(__file__).resolve().parents[2]
WORKFLOW = REPO / ".github" / "workflows" / "unit-testing.yml"
ASSEMBLE = "Assemble the site with the newest reports"
PUBLISH = "Publish to GitHub Pages"


def _steps():
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["publish-report"]["steps"]


def _step(name):
    return next(s for s in _steps() if s.get("name") == name)


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _pages_remote(tmp_path, report_numbers):
    src = tmp_path / "pages-src"
    (src / "operations").mkdir(parents=True)
    (src / "operations" / "reset-account.html").write_text("ops")
    (src / ".nojekyll").write_text("")
    for n in report_numbers:
        d = src / "test-reports" / str(n)
        d.mkdir(parents=True)
        (d / "test-report.html").write_text(f"report {n}")
    _git(src, "init", "-q", "-b", "gh-pages")
    _git(src, "add", "-A")
    _git(src, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "seed")
    return src


def _assemble(tmp_path, remote, keep):
    work = tmp_path / "job"
    new = work / "test-reports" / "900"
    new.mkdir(parents=True)
    (new / "test-report.html").write_text("report 900")
    step = _step(ASSEMBLE)
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
           "HOME": str(tmp_path), **{k: str(v) for k, v in step["env"].items()},
           "KEEP_REPORTS": str(keep), "PAGES_REMOTE": str(remote)}
    return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", step["run"]], cwd=work,
                          env=env, capture_output=True, text=True), work / "site"


def test_only_the_newest_reports_and_the_other_pages_are_published(tmp_path):
    remote = _pages_remote(tmp_path, [5, 40, 100, 899])

    result, site = _assemble(tmp_path, remote, keep=3)

    assert result.returncode == 0, result.stderr
    kept = sorted(p.name for p in (site / "test-reports").iterdir() if p.is_dir())
    assert kept == ["100", "899", "900"], "the new report counts toward the newest three"
    assert (site / "operations" / "reset-account.html").read_text() == "ops"
    assert not (site / ".git").exists()


def test_a_failed_clone_fails_the_step_so_the_old_reports_are_not_wiped(tmp_path):
    """Publishing is a force-push of the whole site, so a site built without the
    existing reports would delete them."""
    result, _ = _assemble(tmp_path, tmp_path / "no-such-remote", keep=3)

    assert result.returncode != 0
    assert _step(ASSEMBLE)["id"] == "assemble"
    assert _step(PUBLISH)["if"] == "steps.assemble.outcome == 'success'"


def test_publish_replaces_the_site_and_drops_branch_history():
    publish = _step(PUBLISH)["with"]

    assert publish["publish_dir"] == "./site"
    assert publish.get("keep_files", False) is False
    assert publish["force_orphan"] is True
    assert "destination_dir" not in publish
