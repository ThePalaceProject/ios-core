"""Tests for scripts/check-comment-hygiene.py."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[2]
_SCRIPT = _REPO / "scripts" / "check-comment-hygiene.py"

CLEAN = """//
//  Clean.swift
//  Palace
//

import Foundation

/// Refreshes the licensor before activation; Adobe rejects a token past its
/// 60-minute expiry (PP-4822, docs/architecture/adobe-activation.md).
struct Clean {
    let url = "https://example.com/path // not a comment swarm_1234abcd"
    let raw = #"a "quoted" // swarm_raw0001"#
    let multi = \"\"\"
        // Wave 3 inside a multi-line string
        \"\"\"
    func add(_ a: Int, _ b: Int) -> Int { a + b } // wave shape of the curve
}
"""


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True,
                          text=True).stdout


def run(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(_SCRIPT), "--root", str(root), *args],
                          cwd=root, capture_output=True, text=True, timeout=60)


def write(root: Path, rel: str, text: str) -> Path:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    return p


def test_clean_file_passes_including_comment_markers_inside_strings(tmp_path):
    write(tmp_path, "Palace/Clean.swift", CLEAN)
    r = run(tmp_path)
    assert r.returncode == 0, r.stdout


@pytest.mark.parametrize("comment,label", [
    ("// Extracted in swarm_47883816 B3.", "swarm ID"),
    ("// The swarm moved this.", "swarm ID"),
    ("// Wave 2b dormant gate.", "wave ID"),
    ("// See .forgeos/intent/pp-4997.md", ".forgeos/ path"),
    ("// Wall-failure 2026-06-05-arch1.md", "wall-failure reference"),
    ("// Per CLAUDE.md rule #4.", "CLAUDE.md citation"),
    ("// The architect reviewer found a race here.", "reviewer-role narrative"),
    ("// Flagged by SoD reviewers.", "reviewer-role narrative"),
    ("// blast_radius noted this.", "reviewer-role narrative"),
    ("// Fixed in review round 3.", "reviewer-round narrative"),
    ("// Pins rev_742175c0.", "review ID"),
])
def test_each_banned_pattern_is_reported_with_its_line(tmp_path, comment, label):
    write(tmp_path, "PalaceTests/FooTests.swift", f"import XCTest\n\nfinal class FooTests {{\n    {comment}\n}}\n")
    r = run(tmp_path)
    assert r.returncode == 1
    assert f"PalaceTests/FooTests.swift:4: {label}" in r.stdout, r.stdout


def test_block_comment_and_objc_files_are_scanned(tmp_path):
    write(tmp_path, "Palace/OPDS/Feed.m", "#import <Foundation/Foundation.h>\n/* moved in\n   Wave 3 */\n")
    r = run(tmp_path)
    assert r.returncode == 1
    assert "Palace/OPDS/Feed.m:3: wave ID" in r.stdout


def test_files_outside_palace_and_palacetests_are_ignored(tmp_path):
    write(tmp_path, "scripts/Tool.swift", "// swarm_47883816\n")
    write(tmp_path, "ios-audiobooktoolkit/X.swift", "// swarm_47883816\n")
    write(tmp_path, "Palace/notes.md", "swarm_47883816\n")
    r = run(tmp_path)
    assert r.returncode == 0, r.stdout


def test_header_of_exactly_15_lines_passes_and_16_fails(tmp_path):
    ok = "".join(f"// line {i}\n" for i in range(15)) + "\nimport Foundation\n"
    long = "".join(f"// line {i}\n" for i in range(16)) + "\nimport Foundation\n"
    write(tmp_path, "Palace/Ok.swift", ok)
    r = run(tmp_path)
    assert r.returncode == 0, r.stdout
    write(tmp_path, "Palace/Long.swift", long)
    r = run(tmp_path)
    assert r.returncode == 1
    assert "Palace/Long.swift:1: file header comment is 16 lines" in r.stdout
    assert "Ok.swift" not in r.stdout


def test_block_comment_header_is_measured(tmp_path):
    header = "/*\n" + "".join(f" * design note {i}\n" for i in range(20)) + " */\nimport Foundation\n"
    write(tmp_path, "Palace/Essay.swift", header)
    r = run(tmp_path)
    assert r.returncode == 1
    assert "file header comment is 22 lines" in r.stdout


def test_long_comment_after_code_is_not_a_header(tmp_path):
    body = "import Foundation\n\n" + "".join(f"// note {i}\n" for i in range(30)) + "struct A {}\n"
    write(tmp_path, "Palace/A.swift", body)
    r = run(tmp_path)
    assert r.returncode == 0, r.stdout


def _repo_with_existing_violation(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    write(repo, "Palace/Old.swift", "import Foundation\n// swarm_aaaaaaaa legacy\nstruct Old {}\n")
    _git(repo, "init", "-q")
    _git(repo, "add", "-A")
    _git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")
    return repo


def test_diff_mode_reports_only_added_lines(tmp_path):
    repo = _repo_with_existing_violation(tmp_path)
    write(repo, "Palace/Old.swift",
          "import Foundation\n// swarm_aaaaaaaa legacy\nstruct Old {}\n// Wave 4 new note\n")
    _git(repo, "add", "-A")
    diff = tmp_path / "staged.diff"
    diff.write_text(_git(repo, "diff", "--cached"))
    r = run(repo, "--diff", str(diff))
    assert r.returncode == 1
    assert "Palace/Old.swift:4: wave ID" in r.stdout
    assert ":2:" not in r.stdout, "pre-existing line must not be reported in diff mode"


def test_diff_mode_clean_change_passes_despite_legacy_violation(tmp_path):
    repo = _repo_with_existing_violation(tmp_path)
    write(repo, "Palace/New.swift", "import Foundation\n// Retries once; the CM returns 503 on cold start.\n")
    _git(repo, "add", "-A")
    diff = tmp_path / "staged.diff"
    diff.write_text(_git(repo, "diff", "--cached"))
    r = run(repo, "--diff", str(diff))
    assert r.returncode == 0, r.stdout


def test_diff_mode_empty_diff_passes(tmp_path):
    repo = _repo_with_existing_violation(tmp_path)
    diff = tmp_path / "empty.diff"
    diff.write_text("")
    r = run(repo, "--diff", str(diff))
    assert r.returncode == 0, r.stdout


def test_base_mode_includes_uncommitted_edits(tmp_path):
    repo = _repo_with_existing_violation(tmp_path)
    _git(repo, "branch", "base")
    write(repo, "PalaceTests/T.swift", "import XCTest\n// rev_742175c0 pinned\n")
    r = run(repo, "--base", "base")
    assert r.returncode == 1
    assert "PalaceTests/T.swift:2: review ID" in r.stdout
    assert "Old.swift" not in r.stdout


def test_missing_diff_file_is_an_input_error(tmp_path):
    r = run(tmp_path, "--diff", str(tmp_path / "nope.diff"))
    assert r.returncode == 2


def _hook_repo(tmp_path: Path, comment: str) -> Path:
    """A throwaway repo whose scripts/ is the real one, with a critical-path
    file staged so the tracked pre-commit hook runs in block mode."""
    repo = tmp_path / "hookrepo"
    repo.mkdir()
    (repo / "scripts").symlink_to(_REPO / "scripts")
    write(repo, "CLAUDE.md", "")
    _git(repo, "init", "-q")
    _git(repo, "add", "CLAUDE.md")
    _git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")
    write(repo, "Palace/SignInLogic/Note.swift", f"import Foundation\n{comment}\nstruct Note {{}}\n")
    _git(repo, "add", "Palace")
    return repo


def _run_hook(repo: Path) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(repo / "scripts" / "git-hooks" / "pre-commit")],
                          cwd=repo, capture_output=True, text=True, timeout=120)


def test_tracked_pre_commit_hook_blocks_a_violating_comment(tmp_path):
    r = _run_hook(_hook_repo(tmp_path, "// Extracted in swarm_47883816."))
    assert r.returncode != 0
    assert "comment_hygiene FAIL" in r.stderr, r.stderr


def test_tracked_pre_commit_hook_passes_a_clean_comment(tmp_path):
    r = _run_hook(_hook_repo(tmp_path, "// Retries once; the server returns 503 on cold start."))
    assert "comment_hygiene" not in r.stderr, r.stderr
