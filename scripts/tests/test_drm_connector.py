"""Tests for scripts/drm_connector.py: the connector record, the local clone,
and the drift check that compares a local connector tree with the record.
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


CERT_SHIPPED_SHA = "855e8752fab169afd262102f75f3b22d793d013e"

CERT_ACTION_TEMPLATE = """name: 'Checkout Certificates'
inputs:
  token:
    required: true
  path:
    default: "./mobile-certificates"
  ref:
    default: "{ref}"
  repo:
    default: "{repo}"
  paths:
    default: "{paths}"
  tooling:
    default: "{tooling}"
runs:
  using: "composite"
  steps: []
"""

BUILD_FILE = "Certificates/Palace/iOS/AddLCP.swift"
TOOLING_FILE = "Certificates/Palace/iOS/ReleaseNotes.py"


def write_cert_action(root: Path, ref: str, repo: str = "Org/certs",
                      paths: str = BUILD_FILE, tooling: str = TOOLING_FILE) -> None:
    path = root / ".github" / "actions" / "checkout-certificates" / "action.yml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(CERT_ACTION_TEMPLATE.format(ref=ref, repo=repo, paths=paths, tooling=tooling))


def commit_files(repo: Path, files: dict, message: str) -> str:
    for rel, content in files.items():
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / rel).write_text(content)
        git("add", rel, cwd=repo)
    git("commit", "-q", "-m", message, cwd=repo)
    return git("rev-parse", "HEAD", cwd=repo)


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


def test_committed_certificates_record_names_the_commit_3_4_1_used():
    record = drm_connector.read_record(REPO, "certificates")
    assert record["sha"] == CERT_SHIPPED_SHA
    assert record["repo"] == "ThePalaceProject/mobile-certificates"


CENSUS_BUILD_FILES = {
    "Certificates/Palace/iOS/AddLCP.swift",
    "Certificates/Palace/iOS/GoogleService-Info.plist",
    "Certificates/Palace/iOS/ReaderClientCert.sig",
    "Certificates/Palace/iOS/KeyObfuscator.swift",
    "Certificates/Palace/iOS/APIKeys.json",
}


def certificates_paths_used_by_scripts() -> set:
    """Every mobile-certificates path a script or workflow reads, derived from
    the files themselves: literal `mobile-certificates/...` paths, and
    `$VAR/...` uses of a variable assigned a `mobile-certificates/...` path."""
    found = set()
    sources = [p for p in (REPO / "scripts").rglob("*") if p.is_file() and p.suffix in {".sh", ".py", ".rb"}
               and "tests" not in p.relative_to(REPO / "scripts").parts]
    sources += list((REPO / ".github").rglob("*.yml"))
    for source in sources:
        text = source.read_text(errors="replace")
        variables = {}
        for name, sub in re.findall(r'(\w+)="[^"]*mobile-certificates/([^"$\s]+)"', text):
            variables[name] = sub.rstrip("/")
        for match in re.findall(r'mobile-certificates/([A-Za-z0-9_./-]+)', text):
            if any(match == sub for sub in variables.values()):
                continue  # the assignment itself; its uses are expanded below
            found.add(match.rstrip("/"))
        for name, sub in variables.items():
            for rest in re.findall(r'\$\{?' + name + r'\}?/([A-Za-z0-9_./-]+)', text):
                found.add(f"{sub}/{rest}")
    return found


def covered(path: str, entries: list) -> bool:
    return any(path == entry or path.startswith(entry.rstrip("/") + "/") for entry in entries)


def test_census_finds_the_certificates_files_the_scripts_read():
    # Shows the scan is able to find uses, so an empty result cannot pass.
    used = certificates_paths_used_by_scripts()
    assert CENSUS_BUILD_FILES | {TOOLING_FILE} <= used


def test_every_certificates_path_a_script_reads_is_in_the_record():
    record = drm_connector.read_record(REPO, "certificates")
    entries = record["paths"] + record["tooling"]
    uncovered = sorted(p for p in certificates_paths_used_by_scripts() if not covered(p, entries))
    assert uncovered == []


def test_committed_certificates_record_checks_the_build_files_not_the_tooling():
    record = drm_connector.read_record(REPO, "certificates")
    assert set(record["paths"]) == CENSUS_BUILD_FILES
    assert record["tooling"] == [TOOLING_FILE]


def test_certificates_record_without_paths_is_an_error(tmp_path):
    write_cert_action(tmp_path, ref=CERT_SHIPPED_SHA, paths="")
    with pytest.raises(drm_connector.RecordError, match="paths"):
        drm_connector.read_record(tmp_path, "certificates")


def test_certificates_record_needs_no_generation(tmp_path):
    write_cert_action(tmp_path, ref=CERT_SHIPPED_SHA)
    assert run_cli("get", "--input", "certificates", "sha", root=tmp_path).stdout.strip() == CERT_SHIPPED_SHA


def test_get_of_a_field_the_record_lacks_exits_3(tmp_path):
    write_cert_action(tmp_path, ref=CERT_SHIPPED_SHA)
    result = run_cli("get", "--input", "certificates", "generation", root=tmp_path)
    assert result.returncode == 3
    assert "has no generation" in result.stderr


def test_certificates_record_rejects_a_branch_name(tmp_path):
    write_cert_action(tmp_path, ref="main")
    with pytest.raises(drm_connector.RecordError, match="40-character"):
        drm_connector.read_record(tmp_path, "certificates")


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


@pytest.mark.parametrize("name", ["checkout-adobe", "checkout-certificates"])
def test_action_checks_out_the_recorded_ref_and_verifies_it(name):
    action = (REPO / f".github/actions/{name}/action.yml").read_text()
    assert "ref: ${{ inputs.ref }}" in action
    assert 'test "$actual" = "$RECORDED_SHA"' in action


def test_workflows_check_out_certificates_only_through_the_record():
    # A direct actions/checkout of the repository would fetch its default
    # branch, not the recorded commit.
    direct, through = [], []
    for workflow in sorted((REPO / ".github" / "workflows").glob("*.yml")):
        text = workflow.read_text()
        if "repository: ThePalaceProject/mobile-certificates" in text:
            direct.append(workflow.name)
        if "uses: ./.github/actions/checkout-certificates" in text:
            through.append(workflow.name)
            # A local action needs the repository checked out first.
            assert text.index("actions/checkout@") < text.index("./.github/actions/checkout-certificates"), workflow.name
    assert direct == []
    assert len(through) == 8


def test_no_workflow_overrides_the_certificates_record():
    offenders = []
    for workflow in sorted((REPO / ".github" / "workflows").glob("*.yml")):
        lines = workflow.read_text().splitlines()
        for i, line in enumerate(lines):
            if "uses: ./.github/actions/checkout-certificates" not in line:
                continue
            for following in lines[i + 1:]:
                stripped = following.lstrip()
                if stripped.startswith("- "):
                    break
                if re.match(r"(ref|repo):", stripped):
                    offenders.append(f"{workflow.name}: {stripped}")
    assert offenders == []


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
    pins = {}
    for name in ("mobile-certificates", "ios-audiobook-overdrive"):
        other = remotes / f"{name}.git"
        other.mkdir()
        git("init", "-q", "-b", "main", cwd=other)
        pins[name] = commit(other, f"{name} pinned")
        pins[f"{name} tip"] = commit(other, f"{name} later")
    shas = {**shas, **pins}
    root = tmp_path / "work" / "app"
    (root / "scripts").mkdir(parents=True)
    write_action(root, ref=shas["pinned"], repo="ThePalaceProject/ios-drm-adeptconnector")
    write_cert_action(root, ref=pins["mobile-certificates"], repo="ThePalaceProject/mobile-certificates")
    # The app repository records the overdrive submodule as a gitlink.
    git("init", "-q", cwd=root)
    git("update-index", "--add", "--cacheinfo",
        f"160000,{pins['ios-audiobook-overdrive']},ios-audiobook-overdrive", cwd=root)
    git("commit", "-q", "-m", "gitlink", cwd=root)
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


def test_bootstrap_checks_out_the_recorded_certificates_commit(bootstrap_sandbox):
    root, shas, calls, run = bootstrap_sandbox
    result = run()
    assert result.returncode == 0, result.stdout + result.stderr
    certs = root.parent / "mobile-certificates"
    assert git("rev-parse", "HEAD", cwd=certs) == shas["mobile-certificates"]


def test_bootstrap_checks_out_overdrive_at_the_submodule_commit(bootstrap_sandbox):
    root, shas, calls, run = bootstrap_sandbox
    result = run()
    assert result.returncode == 0, result.stdout + result.stderr
    overdrive = root.parent / "ios-audiobook-overdrive"
    assert git("rev-parse", "HEAD", cwd=overdrive) == shas["ios-audiobook-overdrive"]


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


def test_setup_repo_drm_run_twice_replaces_the_link_and_writes_nothing_in_the_connector(linked):
    # `ln -sf` over an existing link to a directory follows it and creates a
    # stray link inside the connector checkout; the second run must not.
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    (root / "adobe-rmsdk").unlink()
    (root / "scripts").mkdir()
    for script in ("setup-repo-drm.sh", "drm_connector.py"):
        (root / "scripts" / script).write_text((REPO / "scripts" / script).read_text())
    connector.rename(root / "ios-drm-adeptconnector")
    connector = root / "ios-drm-adeptconnector"
    (root.parent / "mobile-certificates").rename(root / "mobile-certificates")
    env = {**os.environ, "BUILD_CONTEXT": "ci"}
    env.pop("ADEPT_RMSDK", None)
    for _ in range(2):
        result = subprocess.run(["bash", "scripts/setup-repo-drm.sh"], cwd=root, env=env,
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
    assert os.readlink(root / "adobe-rmsdk") == "./ios-drm-adeptconnector/connector"
    assert git("status", "--porcelain", cwd=connector) == ""


# ---------- the drift check ---------------------------------------------------

@pytest.fixture
def linked(tmp_path, remote):
    """An app root whose adobe-rmsdk links into a clone of the remote, with a
    certificates checkout beside it at its recorded commit."""
    remote_path, shas = remote
    connector = tmp_path / "ios-drm-adeptconnector"
    subprocess.run(["git", "clone", "-q", str(remote_path), str(connector)], check=True)
    certs = tmp_path / "mobile-certificates"
    certs.mkdir()
    git("init", "-q", "-b", "main", cwd=certs)
    cert_pin = commit_files(certs, {BUILD_FILE: "lcp 4.1.0", TOOLING_FILE: "notes v1"}, "certs pinned")
    cert_tip = commit_files(certs, {BUILD_FILE: "lcp 4.2.0"}, "certs later")
    git("checkout", "-q", "--detach", cert_pin, cwd=certs)
    root = tmp_path / "app"
    root.mkdir()
    write_action(root, ref=shas["pinned"])
    write_cert_action(root, ref=cert_pin)
    (root / "adobe-rmsdk").symlink_to(connector / "connector")
    return root, connector, {**shas, "cert_pin": cert_pin, "cert_tip": cert_tip}


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


def test_check_fails_when_a_certificates_build_file_differs_from_the_record(linked):
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    certs = root.parent / "mobile-certificates"
    git("checkout", "-q", "--detach", shas["cert_tip"], cwd=certs)
    result = run_cli("check", root=root)
    assert result.returncode == 1
    assert BUILD_FILE in result.stdout
    assert f"checkout {shas['cert_pin']} -- {BUILD_FILE}" in result.stdout


def test_check_passes_when_only_certificates_tooling_differs(linked):
    # mobile-certificates also hosts tooling developed in place; commits and
    # edits to files the build does not read are not drift.
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    certs = root.parent / "mobile-certificates"
    git("checkout", "-q", "-b", "tooling-work", cwd=certs)
    commit_files(certs, {TOOLING_FILE: "notes v2"}, "tooling commit")
    (certs / TOOLING_FILE).write_text("notes v3, not committed")
    result = run_cli("check", root=root)
    assert result.returncode == 0, result.stdout
    assert "build files match" in result.stdout


def test_check_fails_on_an_uncommitted_change_to_a_certificates_build_file(linked):
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    certs = root.parent / "mobile-certificates"
    (certs / BUILD_FILE).write_text("edited in place")
    result = run_cli("check", root=root)
    assert result.returncode == 1
    assert BUILD_FILE in result.stdout


def test_check_fails_when_the_recorded_certificates_commit_is_not_fetched(linked):
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    write_cert_action(root, ref="1" * 40)
    result = run_cli("check", root=root)
    assert result.returncode == 1
    assert "fetch origin" in result.stdout


def test_check_reports_a_recorded_path_missing_from_the_recorded_commit(linked):
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    write_cert_action(root, ref=shas["cert_pin"], paths=f"{BUILD_FILE} Certificates/Palace/iOS/Gone.plist")
    result = run_cli("check", root=root)
    assert result.returncode == 3
    assert "Gone.plist" in result.stdout


def test_check_fails_when_a_drm_setup_has_no_certificates_checkout(linked):
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    (root.parent / "mobile-certificates").rename(root.parent / "moved-away")
    result = run_cli("check", root=root)
    assert result.returncode == 1
    assert "no certificates checkout" in result.stdout


def test_check_reads_certificates_inside_the_repo_in_ci(linked):
    # CI checks the repository out to ./mobile-certificates; local setup uses
    # the sibling ../mobile-certificates, as build-carthage.sh does.
    root, connector, shas = linked
    git("checkout", "-q", "--detach", shas["pinned"], cwd=connector)
    assert run_cli("check", root=root, env={"BUILD_CONTEXT": "ci"}).returncode == 1
    (root.parent / "mobile-certificates").rename(root / "mobile-certificates")
    result = run_cli("check", root=root, env={"BUILD_CONTEXT": "ci"})
    assert result.returncode == 0, result.stdout


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
