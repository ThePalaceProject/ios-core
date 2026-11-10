"""scripts/fetch-nodrm-submodules.sh, run for real against a fixture superproject.

The noDRM build runs on fork pull requests, where no repository secret exists.
These tests pin what the script does with no credentials: it drops the private
DRM submodules without contacting them, fetches every remaining submodule
(recursively), and fails naming the submodule it could not fetch, so a missing
input is a failed job rather than a build that never ran.

Submodule URLs here are local paths; a URL that points at nothing stands in for
a private repository that an anonymous fetch cannot reach.

prior-art-checked: no existing script under scripts/ fetches submodules
anonymously, and no existing test exercises a submodule fetch.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[2]
_SCRIPT = _REPO / "scripts/fetch-nodrm-submodules.sh"
_PRIVATE = ("adept-ios", "adobe-content-filter", "ios-audiobook-overdrive")

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="needs git")


def _git(cwd: Path, *args: str, env: dict | None = None) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True
    ).stdout


def _isolated_env(home: Path) -> dict:
    """No user or system git config, no prompts: the fork-PR runner's position."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(
        HOME=str(home),
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_GLOBAL=str(home / ".gitconfig"),
        GIT_TERMINAL_PROMPT="0",
        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com",
    )
    # Local-path submodules are refused by default since git 2.38.1.
    (home / ".gitconfig").write_text("[protocol \"file\"]\n\tallow = always\n")
    return env


def _repo_with_file(path: Path, name: str, env: dict) -> Path:
    path.mkdir(parents=True)
    _git(path, "init", "-q", "-b", "main", env=env)
    (path / name).write_text(name)
    _git(path, "add", name, env=env)
    _git(path, "commit", "-q", "-m", name, env=env)
    return path


def _superproject(tmp: Path, env: dict, *, public_url_override: str | None = None) -> Path:
    """A superproject shaped like ios-core: public submodules (one nested) plus
    the private DRM ones, which point at URLs that do not exist."""
    nested = _repo_with_file(tmp / "src/nested", "nested.txt", env)
    toolkit = _repo_with_file(tmp / "src/toolkit", "toolkit.txt", env)
    _git(toolkit, "submodule", "add", "-q", str(nested), "Nested", env=env)
    _git(toolkit, "commit", "-q", "-m", "nested", env=env)
    covers = _repo_with_file(tmp / "src/covers", "covers.txt", env)

    sup = tmp / "sup"
    sup.mkdir()
    _git(sup, "init", "-q", "-b", "main", env=env)
    _git(sup, "submodule", "add", "-q", str(toolkit), "ios-audiobooktoolkit", env=env)
    _git(sup, "submodule", "add", "-q", str(covers), "ios-tenprintcover", env=env)
    for name in _PRIVATE:
        # Registered with a real commit, but the URL is unreachable, as a
        # private GitHub repository is to an anonymous fetch.
        priv = _repo_with_file(tmp / f"src/{name}", f"{name}.txt", env)
        _git(sup, "submodule", "add", "-q", str(priv), name, env=env)
        _git(sup, "config", "-f", ".gitmodules", f"submodule.{name}.url",
             str(tmp / f"missing/{name}"), env=env)
    if public_url_override is not None:
        _git(sup, "config", "-f", ".gitmodules", "submodule.ios-tenprintcover.url",
             public_url_override, env=env)
    _git(sup, "add", ".gitmodules", env=env)
    _git(sup, "commit", "-q", "-m", "submodules", env=env)

    # A fresh clone without submodules: what `actions/checkout` leaves with
    # `submodules: false`.
    clone = tmp / "clone"
    _git(tmp, "clone", "-q", str(sup), str(clone), env=env)
    for name in _PRIVATE:
        shutil.rmtree(tmp / f"src/{name}")
    return clone


def _run(clone: Path, env: dict) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(_SCRIPT)], cwd=clone, env=env,
        capture_output=True, text=True, timeout=120,
    )


def test_fetches_public_submodules_recursively_without_the_private_ones(tmp_path):
    env = _isolated_env(tmp_path)
    clone = _superproject(tmp_path, env)

    result = _run(clone, env)

    assert result.returncode == 0, result.stdout + result.stderr
    assert (clone / "ios-audiobooktoolkit/toolkit.txt").is_file()
    assert (clone / "ios-audiobooktoolkit/Nested/nested.txt").is_file()
    assert (clone / "ios-tenprintcover/covers.txt").is_file()
    registered = _git(clone, "config", "-f", ".gitmodules", "--list", env=env)
    for name in _PRIVATE:
        assert not (clone / name / f"{name}.txt").exists(), f"{name} was fetched"
        assert f"submodule.{name}." not in registered, f"{name} is still registered"


def test_an_unreachable_public_submodule_fails_and_names_it(tmp_path):
    env = _isolated_env(tmp_path)
    missing = str(tmp_path / "gone/ios-tenprintcover")
    clone = _superproject(tmp_path, env, public_url_override=missing)

    result = _run(clone, env)

    assert result.returncode != 0, "a missing build input must fail the job"
    assert "ios-tenprintcover" in result.stderr
    assert missing in result.stderr


def test_a_second_run_succeeds(tmp_path):
    """Contributors run setup more than once; the removal must be idempotent."""
    env = _isolated_env(tmp_path)
    clone = _superproject(tmp_path, env)
    assert _run(clone, env).returncode == 0

    result = _run(clone, env)

    assert result.returncode == 0, result.stdout + result.stderr
    assert (clone / "ios-audiobooktoolkit/toolkit.txt").is_file()


def test_a_github_ssh_url_is_fetched_over_https_without_credentials(tmp_path):
    """The .gitmodules URLs use `git@github.com:` and a runner has no SSH key.
    A recording ssh stub proves the fetch never goes over SSH, and a recording
    credential helper in the user config proves it never asks for credentials."""
    env = _isolated_env(tmp_path)
    clone = _superproject(tmp_path, env)
    # Point the public submodule at github over SSH; the HTTPS rewrite then
    # reaches a repository that does not exist, so the fetch fails, but only
    # after showing which transport and which credentials it used.
    _git(clone, "config", "-f", ".gitmodules", "submodule.ios-tenprintcover.url",
         "git@github.com:ThePalaceProject/does-not-exist-pp5520.git", env=env)
    ssh_log = tmp_path / "ssh.log"
    cred_log = tmp_path / "cred.log"
    stub = tmp_path / "ssh-stub"
    stub.write_text(f"#!/bin/sh\necho \"$@\" >> {ssh_log}\nexit 1\n")
    stub.chmod(0o755)
    helper = tmp_path / "cred-helper"
    helper.write_text(f"#!/bin/sh\necho \"$1\" >> {cred_log}\n")
    helper.chmod(0o755)
    with open(env["GIT_CONFIG_GLOBAL"], "a") as cfg:
        cfg.write(f"[credential]\n\thelper = {helper}\n")
    env["GIT_SSH_COMMAND"] = str(stub)

    result = _run(clone, env)

    assert result.returncode != 0
    assert "https://github.com/ThePalaceProject/does-not-exist-pp5520.git" in result.stderr
    assert not ssh_log.exists(), f"the fetch used SSH: {ssh_log.read_text()}"
    assert not cred_log.exists(), f"the fetch asked for credentials: {cred_log.read_text()}"
