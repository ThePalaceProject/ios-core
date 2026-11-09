"""Tests for scripts/drm_connector.py: the connector record, the local clone,
and the drift check that compares a local connector tree with the record.

prior-art-checked: nothing in the harness reads this repository's connector record.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "drm_connector.py"
sys.path.insert(0, str(REPO / "scripts"))
import drm_connector  # noqa: E402

SHIPPED_SHA = "7913158fa6b04ef8387a0b3bf32454bd795284fb"

ACTION_TEMPLATE = """name: 'Checkout Adobe RMSDK'
inputs:
  token:
    required: true
  path:
    default: "./ios-drm-adeptconnector"
  ref:
    description: "Connector commit"
    default: "{ref}"
  generation:
    default: "{generation}"
  repo:
    default: "{repo}"
runs:
  using: "composite"
  steps: []
"""


def write_action(root: Path, ref: str, generation: str = "2", repo: str = "Org/connector") -> None:
    path = root / ".github" / "actions" / "checkout-adobe" / "action.yml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(ACTION_TEMPLATE.format(ref=ref, generation=generation, repo=repo))


def git(*args: str, cwd: Path) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True,
                          capture_output=True, text=True).stdout.strip()


def commit(repo: Path, name: str) -> str:
    (repo / "connector").mkdir(exist_ok=True)
    (repo / "connector" / "lib.a").write_text(name)
    git("add", "connector/lib.a", cwd=repo)
    git("commit", "-q", "-m", name, cwd=repo)
    return git("rev-parse", "HEAD", cwd=repo)


def run_cli(*args: str, root: Path, env: dict | None = None) -> subprocess.CompletedProcess:
    full_env = {k: v for k, v in os.environ.items() if k != "ADEPT_RMSDK"}
    full_env.update(env or {})
    return subprocess.run([sys.executable, str(SCRIPT), "--repo-root", str(root), *args],
                          capture_output=True, text=True, env=full_env)


def route_github_to(remote_path: Path) -> dict:
    """Env that makes git fetch git@github.com:Org/<name> from a local fixture."""
    return {"GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": f"url.{remote_path.parent}/.insteadOf",
            "GIT_CONFIG_VALUE_0": "git@github.com:Org/"}


# ---------- the record --------------------------------------------------------

def test_committed_record_names_the_commit_every_3_4_1_build_used():
    record = drm_connector.read_record(REPO)
    assert record["sha"] == SHIPPED_SHA
    assert record["repo"] == "ThePalaceProject/ios-drm-adeptconnector"


def test_committed_record_generation_matches_the_app_constant():
    # The record's generation restates AdobeConnectorGeneration.current; if the
    # two disagree the record misdescribes the build.
    swift = (REPO / "Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeConnectorGeneration.swift").read_text()
    current = re.search(r"static let current = (\d+)", swift)
    assert current, "AdobeConnectorGeneration.current not found"
    assert drm_connector.read_record(REPO)["generation"] == current.group(1)


@pytest.mark.parametrize("ref", ["feature/bytebooks-connector-20261104", "7913158", SHIPPED_SHA.upper()])
def test_record_rejects_a_ref_that_is_not_a_full_commit_sha(tmp_path, ref):
    write_action(tmp_path, ref=ref)
    with pytest.raises(drm_connector.RecordError, match="40-character"):
        drm_connector.read_record(tmp_path)


def test_record_without_a_generation_is_an_error(tmp_path):
    write_action(tmp_path, ref=SHIPPED_SHA, generation="")
    with pytest.raises(drm_connector.RecordError, match="generation"):
        drm_connector.read_record(tmp_path)


def test_record_with_a_non_integer_generation_is_an_error(tmp_path):
    write_action(tmp_path, ref=SHIPPED_SHA, generation="bytebooks")
    with pytest.raises(drm_connector.RecordError, match="not an integer"):
        drm_connector.read_record(tmp_path)


def test_get_prints_each_field_from_the_record(tmp_path):
    write_action(tmp_path, ref=SHIPPED_SHA, generation="7", repo="Org/conn")
    assert run_cli("get", "sha", root=tmp_path).stdout.strip() == SHIPPED_SHA
    assert run_cli("get", "generation", root=tmp_path).stdout.strip() == "7"
    assert run_cli("get", "repo", root=tmp_path).stdout.strip() == "Org/conn"


def test_unreadable_record_exits_3(tmp_path):
    result = run_cli("check", root=tmp_path)
    assert result.returncode == 3
    assert "cannot read" in result.stderr


def test_no_workflow_overrides_the_connector_record():
    # The action's defaults are the only record; a workflow passing `ref` or
    # `repo` to it would build a different connector from local setup.
    offenders = []
    for workflow in sorted((REPO / ".github" / "workflows").glob("*.yml")):
        lines = workflow.read_text().splitlines()
        for i, line in enumerate(lines):
            if "uses: ./.github/actions/checkout-adobe" not in line:
                continue
            indent = len(line) - len(line.lstrip())
            for following in lines[i + 1:]:
                stripped = following.lstrip()
                if stripped and len(following) - len(stripped) < indent:
                    break
                if stripped.startswith("- "):
                    break
                if re.match(r"(ref|repo):", stripped):
                    offenders.append(f"{workflow.name}: {stripped}")
    assert offenders == []


def test_action_checks_out_the_recorded_ref_and_verifies_it():
    action = (REPO / ".github/actions/checkout-adobe/action.yml").read_text()
    assert "ref: ${{ inputs.ref }}" in action
    assert 'test "$actual" = "$CONNECTOR_SHA"' in action


# ---------- local setup -------------------------------------------------------

@pytest.fixture
def remote(tmp_path):
    """A connector repo with main and a feature branch; returns (path, shas)."""
    path = tmp_path / "remotes" / "connector.git"
    path.mkdir(parents=True)
    git("init", "-q", "-b", "main", cwd=path)
    main_sha = commit(path, "adobe-era")
    git("checkout", "-q", "-b", "feature/x", cwd=path)
    pinned = commit(path, "bytebooks")
    tip = commit(path, "later drop")
    git("checkout", "-q", "main", cwd=path)
    return path, {"main": main_sha, "pinned": pinned, "tip": tip}


def test_clone_checks_out_the_recorded_commit_not_a_branch_tip(tmp_path, remote):
    remote_path, shas = remote
    root = tmp_path / "app"
    write_action(root, ref=shas["pinned"], repo="Org/connector")
    stub_bin = tmp_path / "bin"
    stub_bin.mkdir()
    lfs_log = tmp_path / "lfs.log"
    (stub_bin / "git-lfs").write_text(
        f'#!/bin/sh\necho "$(git rev-parse HEAD) $*" >> "{lfs_log}"\n')
    (stub_bin / "git-lfs").chmod(0o755)
    env = {"PATH": f"{stub_bin}:{os.environ['PATH']}", **route_github_to(remote_path)}
    dest = tmp_path / "ios-drm-adeptconnector"
    result = run_cli("clone", str(dest), root=root, env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert git("rev-parse", "HEAD", cwd=dest) == shas["pinned"]
    assert (dest / "connector" / "lib.a").read_text() == "bytebooks"
    # LFS objects are fetched for the recorded commit, after it is checked out.
    assert lfs_log.read_text().splitlines() == [f"{shas['pinned']} pull"]


def test_clone_fails_when_the_recorded_commit_does_not_exist(tmp_path, remote):
    remote_path, _ = remote
    root = tmp_path / "app"
    write_action(root, ref="0" * 40, repo="Org/connector")
    result = run_cli("clone", str(tmp_path / "dest"), root=root, env=route_github_to(remote_path))
    assert result.returncode == 1
    assert "checkout --detach" in result.stderr


@pytest.fixture
def bootstrap_sandbox(tmp_path, remote):
    """An app root beside empty sibling slots, with every remote a local fixture.

    Runs the real bootstrap-drm.sh and drm_connector.py; the setup and build
    scripts it calls are stubs that log their names.
    """
    remote_path, shas = remote
    remotes = remote_path.parent
    remote_path.rename(remotes / "ios-drm-adeptconnector.git")
    for name in ("mobile-certificates", "ios-audiobook-overdrive"):
        other = remotes / f"{name}.git"
        other.mkdir()
        git("init", "-q", "-b", "main", cwd=other)
        commit(other, name)
    root = tmp_path / "work" / "app"
    (root / "scripts").mkdir(parents=True)
    write_action(root, ref=shas["pinned"], repo="ThePalaceProject/ios-drm-adeptconnector")
    for script in ("bootstrap-drm.sh", "drm_connector.py"):
        (root / "scripts" / script).write_text((REPO / "scripts" / script).read_text())
    calls = tmp_path / "calls.log"
    for stub in ("setup-repo-drm.sh", "build-3rd-party-dependencies.sh"):
        (root / "scripts" / stub).write_text(f'#!/bin/sh\necho {stub} >> "{calls}"\n')
        (root / "scripts" / stub).chmod(0o755)
    stub_bin = tmp_path / "bin"
    stub_bin.mkdir()
    (stub_bin / "git-lfs").write_text("#!/bin/sh\nexit 0\n")
    (stub_bin / "git-lfs").chmod(0o755)
    env = {**os.environ, "PATH": f"{stub_bin}:{os.environ['PATH']}",
           "GIT_CONFIG_COUNT": "1",
           "GIT_CONFIG_KEY_0": f"url.{remotes}/.insteadOf",
           "GIT_CONFIG_VALUE_0": "git@github.com:ThePalaceProject/"}

    def run():
        return subprocess.run(["bash", "scripts/bootstrap-drm.sh"], cwd=root, env=env,
                              capture_output=True, text=True)

    return root, shas, calls, run


def test_bootstrap_clones_the_recorded_commit_beside_the_app(bootstrap_sandbox):
    root, shas, calls, run = bootstrap_sandbox
    result = run()
    assert result.returncode == 0, result.stdout + result.stderr
    connector = root.parent / "ios-drm-adeptconnector"
    assert git("rev-parse", "HEAD", cwd=connector) == shas["pinned"]
    assert calls.read_text().split() == ["setup-repo-drm.sh", "build-3rd-party-dependencies.sh"]


def test_bootstrap_run_twice_succeeds_and_keeps_the_existing_clones(bootstrap_sandbox):
    root, shas, calls, run = bootstrap_sandbox
    assert run().returncode == 0
    marker = root.parent / "mobile-certificates" / "local-only.txt"
    marker.write_text("kept")
    second = run()
    assert second.returncode == 0, second.stdout + second.stderr
    assert marker.read_text() == "kept"
    assert git("rev-parse", "HEAD", cwd=root.parent / "ios-drm-adeptconnector") == shas["pinned"]
    assert calls.read_text().split().count("setup-repo-drm.sh") == 2


def test_bootstrap_leaves_an_existing_connector_clone_where_it_is(bootstrap_sandbox):
    # A developer's existing clone is not moved; setup-repo-drm.sh's drift
    # check reports it with the commands to fix it.
    root, shas, calls, run = bootstrap_sandbox
    assert run().returncode == 0
    connector = root.parent / "ios-drm-adeptconnector"
    git("checkout", "-q", "feature/x", cwd=connector)
    result = run()
    assert result.returncode == 0, result.stdout + result.stderr
    assert git("rev-parse", "HEAD", cwd=connector) == shas["tip"]
    assert "ios-drm-adeptconnector already exists" in result.stdout


# ---------- the drift check ---------------------------------------------------

@pytest.fixture
def linked(tmp_path, remote):
    """An app root whose adobe-rmsdk links into a clone of the remote."""
    remote_path, shas = remote
    connector = tmp_path / "ios-drm-adeptconnector"
    subprocess.run(["git", "clone", "-q", str(remote_path), str(connector)], check=True)
    root = tmp_path / "app"
    root.mkdir()
    write_action(root, ref=shas["pinned"])
    (root / "adobe-rmsdk").symlink_to(connector / "connector")
    return root, connector, shas


def test_check_passes_when_the_tree_is_at_the_recorded_commit(linked):
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    result = run_cli("check", root=root)
    assert result.returncode == 0, result.stdout
    assert "is at the recorded commit" in result.stdout


def test_check_fails_with_a_fix_hint_when_the_tree_is_at_another_commit(linked):
    root, connector, shas = linked
    git("checkout", "-q", "feature/x", cwd=connector)  # the branch tip, not the pin
    result = run_cli("check", root=root)
    assert result.returncode == 1
    assert shas["tip"] in result.stdout and shas["pinned"] in result.stdout
    assert f"checkout --detach {shas['pinned']}" in result.stdout


def test_check_fails_when_the_tree_has_modified_tracked_files(linked):
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    (connector / "connector" / "lib.a").write_text("hand-edited")
    result = run_cli("check", root=root)
    assert result.returncode == 1
    assert "modified tracked file" in result.stdout


def test_check_reads_the_adept_rmsdk_override_instead_of_the_symlink(linked, tmp_path):
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    other = tmp_path / "other"
    subprocess.run(["git", "clone", "-q", str(connector), str(other)], check=True)
    git("checkout", "-q", "--detach", shas["main"], cwd=other)
    result = run_cli("check", root=root, env={"ADEPT_RMSDK": str(other / "connector")})
    assert result.returncode == 1
    assert shas["main"] in result.stdout


def test_check_without_a_connector_tree_exits_2(tmp_path):
    write_action(tmp_path, ref=SHIPPED_SHA)
    result = run_cli("check", root=tmp_path)
    assert result.returncode == 2
    assert "noDRM" in result.stdout


def test_check_on_a_link_into_a_non_git_directory_exits_3(tmp_path):
    root = tmp_path / "app"
    root.mkdir()
    write_action(root, ref=SHIPPED_SHA)
    plain = tmp_path / "unzipped" / "connector"
    plain.mkdir(parents=True)
    (root / "adobe-rmsdk").symlink_to(plain)
    result = run_cli("check", root=root)
    assert result.returncode == 3
    assert "not inside a git checkout" in result.stdout


def test_check_does_not_read_the_app_checkout_as_the_connector(tmp_path):
    # `adobe-rmsdk/..` names the app checkout; a check that resolved the link
    # that way would compare the app's own HEAD with the record.
    root = tmp_path / "app"
    root.mkdir()
    git("init", "-q", cwd=root)
    write_action(root, ref=SHIPPED_SHA)
    (root / "vendored").mkdir()
    (root / "adobe-rmsdk").symlink_to(root / "vendored")
    result = run_cli("check", root=root)
    assert result.returncode == 3
    assert "resolves into this repository" in result.stdout


# ---------- wiring ------------------------------------------------------------

def test_verify_pr_maps_each_check_exit_status_to_a_leg_status():
    # 0 is a pass, 2 (no connector tree) a skip, 1 and anything else a failure.
    verify = (REPO / "scripts/verify-pr.sh").read_text()
    assert re.search(r'drm_connector\.py"? --repo-root "\$REPO_ROOT" check', verify)
    arms = dict(re.findall(r'^\s*(\S+)\) record "drm_connector" "(\w+)"', verify, re.M))
    assert arms == {"0": "pass", "2": "skip", "1": "fail", "*": "fail"}


def test_setup_repo_drm_runs_the_drift_check_after_linking():
    setup = (REPO / "scripts/setup-repo-drm.sh").read_text()
    link = setup.index("ln -sf")
    assert setup.index("drm_connector.py check", link) > link
