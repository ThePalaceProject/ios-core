"""Tests for scripts/list-known-behaviors.py and its CI summary step."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import yaml

_REPO = Path(__file__).resolve().parents[2]
_SCRIPT = _REPO / "scripts" / "list-known-behaviors.py"

KEYED = "        // Known: PP-1234 an alert still shows after a cancelled borrow\n"
KEYLESS = "        // Known: the retry count is 3 though the server asks for 5\n"
TEST_FILE = "final class BorrowTests {{\n    func testCancel() {{\n{marker}        assertSnapshot()\n    }}\n}}\n"


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *args],
                          cwd=repo, check=True, capture_output=True, text=True).stdout


def _repo(tmp_path: Path, marker: str = "") -> Path:
    repo = tmp_path / "repo"
    (repo / "PalaceTests").mkdir(parents=True)
    _git(repo, "init", "-q", "-b", "main")
    (repo / "PalaceTests" / "BorrowTests.swift").write_text(TEST_FILE.format(marker=marker))
    (repo / "CLAUDE.md").write_text("Example: // Known: PP-9 in prose is not a marker\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "base")
    return repo


def run(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(_SCRIPT), "--root", str(repo), *args],
                          cwd=repo, capture_output=True, text=True, timeout=60)


def test_lists_every_marker_with_location_key_and_text(tmp_path):
    repo = _repo(tmp_path, KEYED)
    r = run(repo)
    assert r.returncode == 0, r.stderr
    assert ("PalaceTests/BorrowTests.swift:3: PP-1234: "
            "PP-1234 an alert still shows after a cancelled borrow") in r.stdout
    assert "1 marker(s) in the tree" in r.stdout


def test_marker_outside_swift_and_objc_sources_is_not_listed(tmp_path):
    r = run(_repo(tmp_path))
    assert r.returncode == 0
    assert "PP-9" not in r.stdout
    assert "0 marker(s)" in r.stdout


def test_marker_without_pp_key_exits_non_zero(tmp_path):
    r = run(_repo(tmp_path, KEYLESS))
    assert r.returncode == 1
    assert "(no PP key)" in r.stdout
    assert "needs a PP key" in r.stderr


def test_diff_base_lists_only_markers_added_since_the_ref(tmp_path):
    repo = _repo(tmp_path, KEYED)
    base = _git(repo, "rev-parse", "HEAD").strip()
    path = repo / "PalaceTests" / "BorrowTests.swift"
    path.write_text(path.read_text().replace(
        "        assertSnapshot()\n", "        assertSnapshot()\n" + KEYED.replace("1234", "5678"), 1))
    _git(repo, "commit", "-qam", "add marker")
    r = run(repo, "--diff-base", base)
    assert r.returncode == 0, r.stderr
    assert "PP-5678" in r.stdout
    assert "PP-1234" not in r.stdout
    assert "PalaceTests/BorrowTests.swift:5:" in r.stdout


def test_diff_base_includes_uncommitted_and_untracked_markers(tmp_path):
    repo = _repo(tmp_path)
    (repo / "PalaceTests" / "NewTests.swift").write_text(KEYED)
    path = repo / "PalaceTests" / "BorrowTests.swift"
    path.write_text(TEST_FILE.format(marker=KEYED.replace("1234", "4321")))
    r = run(repo, "--diff-base", "HEAD")
    assert "PP-1234" in r.stdout and "PP-4321" in r.stdout, r.stdout


def test_clean_diff_lists_nothing(tmp_path):
    repo = _repo(tmp_path, KEYED)
    r = run(repo, "--diff-base", "HEAD")
    assert r.returncode == 0
    assert "0 marker(s) added since HEAD" in r.stdout


def test_diff_base_ignores_keyless_marker_already_in_the_base(tmp_path):
    r = run(_repo(tmp_path, KEYLESS), "--diff-base", "HEAD")
    assert r.returncode == 0, r.stderr


def test_unknown_ref_is_an_input_error(tmp_path):
    r = run(_repo(tmp_path), "--diff-base", "no-such-ref")
    assert r.returncode == 2


def test_markdown_table_escapes_pipes(tmp_path):
    repo = _repo(tmp_path, KEYED.replace("borrow", "borrow | hold"))
    r = run(repo, "--markdown")
    assert "| `PalaceTests/BorrowTests.swift:3` | PP-1234 |" in r.stdout
    assert "borrow \\| hold" in r.stdout


def _summary_step():
    wf = yaml.safe_load((_REPO / ".github" / "workflows" / "tooling-checks.yml").read_text())
    job = wf["jobs"]["flake-lint"]
    return next(s for s in job["steps"] if "list-known-behaviors.py" in s.get("run", ""))


def _run_summary_step(tmp_path: Path, repo: Path):
    (repo / "scripts").mkdir(exist_ok=True)
    (repo / "scripts" / "list-known-behaviors.py").write_text(_SCRIPT.read_text())
    summary = tmp_path / "summary.md"
    env = {**os.environ, "BASE": "main", "GITHUB_STEP_SUMMARY": str(summary)}
    r = subprocess.run(["bash", "-c", _summary_step()["run"]], cwd=repo, env=env,
                       capture_output=True, text=True, timeout=60)
    return r, summary.read_text()


def test_ci_summary_step_lists_pr_and_tree_markers(tmp_path):
    repo = _repo(tmp_path, KEYED)
    _git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    _git(repo, "checkout", "-q", "-b", "pr")
    (repo / "PalaceTests" / "NewTests.swift").write_text(KEYED.replace("1234", "5678"))
    _git(repo, "add", "PalaceTests/NewTests.swift")
    _git(repo, "commit", "-qm", "pr")
    r, summary = _run_summary_step(tmp_path, repo)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Known behaviors kept (1 added since origin/main)" in summary
    assert "Known behaviors kept (2 in the tree)" in summary


def test_ci_summary_step_does_not_block_on_a_keyless_marker(tmp_path):
    repo = _repo(tmp_path, KEYLESS)
    _git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    r, summary = _run_summary_step(tmp_path, repo)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "::warning::" in r.stdout
    assert "| missing |" in summary
