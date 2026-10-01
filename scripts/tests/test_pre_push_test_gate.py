"""Tests for the file-size ceiling step in scripts/pre-push-test-gate.sh.

prior-art-checked: nothing under scripts/tests exercised pre-push-test-gate.sh;
this follows the existing scripts/tests pytest convention.

The hook is run for real against a throwaway repo with a bare origin, with
`check-file-size-ceiling.sh` copied next to it. The fixture has no PalaceTests/,
so after the ceiling step the hook derives no test classes and never reaches
xcodebuild. Each fixture injects its own allowlist through
FILE_SIZE_ALLOWLIST_FILE, the ceiling script's own seam.
"""
import os
import shutil
import subprocess
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
HOOK = SCRIPTS / "pre-push-test-gate.sh"
CEILING = SCRIPTS / "check-file-size-ceiling.sh"

ALLOWLISTED = "Palace/Hub.swift"


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True
    ).stdout


def _swift(lines: int) -> str:
    return "".join(f"let v{i} = {i}\n" for i in range(lines))


def _repo(tmp_path: Path, hub_cap: int, hub_lines: int) -> Path:
    """A repo pushed to its origin, with an allowlisted file at `hub_lines`."""
    origin = tmp_path / "origin.git"
    repo = tmp_path / "repo"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    _git(repo, "config", "commit.gpgsign", "false")
    (repo / "scripts").mkdir()
    shutil.copy(HOOK, repo / "scripts" / HOOK.name)
    shutil.copy(CEILING, repo / "scripts" / CEILING.name)
    (repo / "Palace").mkdir()
    (repo / ALLOWLISTED).write_text(_swift(hub_lines))
    (repo / "Palace" / "Small.swift").write_text(_swift(3))
    (repo / "README.md").write_text("readme\n")
    (tmp_path / "allowlist").write_text(f"{hub_cap} {ALLOWLISTED}\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "base")
    _git(repo, "remote", "add", "origin", str(origin))
    _git(repo, "push", "-q", "-u", "origin", "main")
    return repo


def _commit(repo: Path, rel: str, content: str) -> None:
    (repo / rel).write_text(content)
    _git(repo, "add", rel)
    _git(repo, "commit", "-q", "-m", f"change {rel}")


def _run_hook(repo: Path, tmp_path: Path) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.pop("SKIP_PRE_PUSH_TESTS", None)
    env["FILE_SIZE_ALLOWLIST_FILE"] = str(tmp_path / "allowlist")
    head = _git(repo, "rev-parse", "HEAD").strip()
    refs = f"refs/heads/main {head} refs/heads/main {'0' * 40}\n"
    return subprocess.run(
        ["bash", "scripts/pre-push-test-gate.sh", "origin", str(tmp_path / "origin.git")],
        cwd=repo, env=env, input=refs, capture_output=True, text=True, timeout=120,
    )


def test_push_growing_an_allowlisted_file_past_its_cap_is_blocked(tmp_path):
    repo = _repo(tmp_path, hub_cap=5, hub_lines=5)
    _commit(repo, ALLOWLISTED, _swift(6))

    result = _run_hook(repo, tmp_path)

    assert result.returncode != 0, result.stderr
    assert "OVER-ALLOWLIST" in result.stderr
    assert "file-size ceiling" in result.stderr and "push blocked" in result.stderr


def test_clean_swift_push_runs_the_ceiling_and_passes(tmp_path):
    repo = _repo(tmp_path, hub_cap=5, hub_lines=5)
    _commit(repo, "Palace/Small.swift", _swift(4))

    result = _run_hook(repo, tmp_path)

    assert result.returncode == 0, result.stderr
    assert "[file-size] OK" in result.stderr


def test_non_swift_push_skips_the_ceiling(tmp_path):
    # The tree is already over the cap, so the push would be blocked if the
    # ceiling ran at all. Exit 0 here means the step was skipped.
    repo = _repo(tmp_path, hub_cap=4, hub_lines=5)
    _commit(repo, "README.md", "readme, edited\n")

    result = _run_hook(repo, tmp_path)

    assert result.returncode == 0, result.stderr
    assert "[file-size]" not in result.stderr
