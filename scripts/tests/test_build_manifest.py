"""Tests for scripts/build_manifest.py: the build-input manifest a verification
report carries, and the check that says when a report no longer applies.

prior-art-checked: follows test_drm_connector.py, which builds a throwaway git
repository holding the record files the script reads.
"""

from __future__ import annotations

import json
import os
import platform
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "build_manifest.py"
VERIFY_PR = REPO / "scripts" / "verify-pr.sh"

CONNECTOR_SHA = "7913158fa6b04ef8387a0b3bf32454bd795284fb"
TOOLKIT_SHA = "1111111111111111111111111111111111111111"
OVERDRIVE_SHA = "4444444444444444444444444444444444444444"
CERTS_SHA = "855e8752fab169afd262102f75f3b22d793d013e"
CERT_PATHS = "Certificates/Palace/iOS/AddLCP.swift Certificates/Palace/iOS/ReaderClientCert.sig"
UDID = "11111111-2222-3333-4444-555555555555"

ACTION = """name: 'Checkout Adobe RMSDK'
inputs:
  ref:
    default: "{ref}"
  generation:
    default: "2"
  repo:
    default: "{repo}"
runs:
  using: "composite"
  steps: []
"""

FETCH = """#!/bin/bash
AUDIOENGINE_VERSION="6.5.6"
AUDIOENGINE_SHA256="{sha}"
"""

CERTS_ACTION = """name: 'Checkout Certificates'
inputs:
  ref:
    default: "{ref}"
  repo:
    default: "ThePalaceProject/mobile-certificates"
  paths:
    default: "{paths}"
  tooling:
    default: "Certificates/Palace/iOS/ReleaseNotes.py"
runs:
  using: "composite"
  steps: []
"""

CARTHAGE = """#!/bin/bash
LIBLCP_VERSION="{version}"
LIBLCP_SHA256="{sha}"
"""

TOOLCHAIN = """[reference]
runner_image = macos-15-arm64
xcode_version = 26.3
xcode_build = 17C529
sdk = iphonesimulator26.2
runtime = iOS 18.5
device = iPhone 16 Pro
arch = arm64
configuration = Debug
"""

SIMCTL = {"runtimes": [{"name": "iOS 18.5", "version": "18.5", "isAvailable": True,
                        "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5"}],
          "devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
              {"name": "iPhone 16 Pro", "udid": UDID, "state": "Shutdown", "isAvailable": True}]}}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                          check=True).stdout.strip()


def commit_all(repo: Path, message: str) -> None:
    git(repo, "add", "--", ".github", "scripts", "app.txt")
    git(repo, "commit", "-q", "-m", message)


@pytest.fixture
def tree(tmp_path):
    repo = tmp_path / "repo"
    (repo / ".github/actions/checkout-adobe").mkdir(parents=True)
    (repo / ".github/actions/checkout-certificates").mkdir(parents=True)
    (repo / "scripts").mkdir()
    write_inputs(repo)
    (repo / "app.txt").write_text("app\n")
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "t@example.com")
    git(repo, "config", "user.name", "t")
    git(repo, "update-index", "--add", "--cacheinfo", f"160000,{TOOLKIT_SHA},ios-audiobooktoolkit")
    git(repo, "update-index", "--add", "--cacheinfo", f"160000,{OVERDRIVE_SHA},ios-audiobook-overdrive")
    commit_all(repo, "base")
    (tmp_path / "toolchain.ini").write_text(TOOLCHAIN)
    (tmp_path / "simctl.json").write_text(json.dumps(SIMCTL))
    (tmp_path / "xcode.txt").write_text("Xcode 26.3\nBuild version 17C529\n")
    return repo


def write_inputs(repo: Path, ref: str = CONNECTOR_SHA, sha256: str = "ab" * 32,
                 repo_name: str = "ThePalaceProject/ios-drm-adeptconnector", certs_ref: str = CERTS_SHA,
                 cert_paths: str = CERT_PATHS, lcp_version: str = "4.1.0", lcp_sha256: str = "ef" * 32) -> None:
    (repo / ".github/actions/checkout-adobe/action.yml").write_text(ACTION.format(ref=ref, repo=repo_name))
    (repo / ".github/actions/checkout-certificates/action.yml").write_text(
        CERTS_ACTION.format(ref=certs_ref, paths=cert_paths))
    (repo / "scripts/fetch-audioengine.sh").write_text(FETCH.format(sha=sha256))
    (repo / "scripts/build-carthage.sh").write_text(CARTHAGE.format(version=lcp_version, sha=lcp_sha256))


def run(repo: Path, *args: str, xcode: str | None = None, env: dict | None = None):
    tmp = repo.parent
    base = {k: v for k, v in os.environ.items() if k not in ("GITHUB_ACTIONS", "ImageOS", "ImageVersion")}
    if xcode:
        (tmp / "xcode.txt").write_text(xcode)
    cmd = ["python3", str(SCRIPT), *args, "--repo-root", str(repo), "--toolchain-config", str(tmp / "toolchain.ini"),
           "--simctl-json", str(tmp / "simctl.json"), "--xcode-version-text", str(tmp / "xcode.txt"),
           "--sdk-version", "26.2", "--arch", "arm64"]
    return subprocess.run(cmd, capture_output=True, text=True, env={**base, **(env or {})}, timeout=60)


def write_report(repo: Path, result: str = "passed", env: dict | None = None) -> Path:
    report = repo.parent / "report.json"
    report.write_text(json.dumps({"checks": []}))
    r = run(repo, "write", "--check", "unit-tests", "--result", result, "--udid", UDID,
            "--into", str(report), env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    return report


# --------------------------------------------------------------------------
# What the manifest records
# --------------------------------------------------------------------------

def test_manifest_records_each_pinned_input_from_the_file_that_pins_it(tree):
    r = run(tree, "write", "--check", "unit-tests", "--result", "passed", "--udid", UDID)
    assert r.returncode == 0, r.stderr
    m = json.loads(r.stdout)
    assert m["app"] == {"sha": git(tree, "rev-parse", "HEAD"), "dirty": False}
    assert m["inputs"]["connector"] == {"repo": "ThePalaceProject/ios-drm-adeptconnector",
                                        "sha": CONNECTOR_SHA, "generation": "2"}
    assert m["inputs"]["audioengine"] == {"version": "6.5.6", "sha256": "ab" * 32}
    assert m["inputs"]["toolkit"] == {"recorded_sha": TOOLKIT_SHA}
    assert m["inputs"]["certificates"] == {"repo": "ThePalaceProject/mobile-certificates", "sha": CERTS_SHA,
                                           "paths": CERT_PATHS.split()}
    assert m["inputs"]["liblcp"] == {"version": "4.1.0", "sha256": "ef" * 32}
    assert m["inputs"]["overdrive"] == {"recorded_sha": OVERDRIVE_SHA}
    assert m["toolchain"] == {"xcode_version": "26.3", "xcode_build": "17C529", "sdk": "iphonesimulator26.2",
                              "runtime": "iOS 18.5", "device": "iPhone 16 Pro", "arch": "arm64",
                              "configuration": "Debug"}
    assert (m["check"], m["result"]) == ("unit-tests", "passed")
    assert "runner" not in m, "a local run has no hosted runner image"


def test_into_adds_the_manifest_and_keeps_the_report(tree):
    report = tree.parent / "report.json"
    report.write_text(json.dumps({"pass_count": 3, "checks": [{"check": "build", "status": "pass"}]}))
    r = run(tree, "write", "--check", "verify-pr", "--from-checks", "--into", str(report))
    assert r.returncode == 0, r.stderr
    data = json.loads(report.read_text())
    assert data["pass_count"] == 3 and data["checks"] == [{"check": "build", "status": "pass"}]
    assert data["manifest"]["check"] == "verify-pr"


def test_a_dirty_tree_is_flagged_and_tied_to_its_changes(tree):
    (tree / "app.txt").write_text("edited\n")
    first = json.loads(run(tree, "write", "--check", "c", "--result", "passed").stdout)
    assert first["app"]["dirty"] is True and re.fullmatch(r"[0-9a-f]{64}", first["app"]["diff_sha256"])
    (tree / "app.txt").write_text("edited again\n")
    second = json.loads(run(tree, "write", "--check", "c", "--result", "passed").stdout)
    assert second["app"]["diff_sha256"] != first["app"]["diff_sha256"]


def test_ci_records_the_hosted_runner_image(tree):
    r = run(tree, "write", "--check", "c", "--result", "passed",
            env={"GITHUB_ACTIONS": "true", "ImageOS": "macos15", "ImageVersion": "20261103.1.0"})
    assert json.loads(r.stdout)["runner"] == {"image_os": "macos15", "image_version": "20261103.1.0"}


# --------------------------------------------------------------------------
# Results stay distinct
# --------------------------------------------------------------------------

@pytest.mark.parametrize("result", ["passed", "failed", "skipped", "recovered", "unavailable"])
def test_each_result_is_recorded_as_given(tree, result):
    m = json.loads(run(tree, "write", "--check", "c", "--result", result).stdout)
    assert m["result"] == result


def test_an_unknown_result_is_refused(tree):
    r = run(tree, "write", "--check", "c", "--result", "green")
    assert r.returncode == 2 and "invalid choice" in r.stderr


@pytest.mark.parametrize("statuses, result", [
    (["pass", "skip", "fail"], "failed"),
    (["pass", "skip"], "passed"),
    (["skip", "skip"], "skipped"),
    (["pass", "recovered"], "recovered"),
    ([], "unavailable"),
    (["skip", "unavailable"], "skipped"),
])
def test_from_checks_reports_the_worst_outcome_that_ran_and_counts_every_status(tree, statuses, result):
    report = tree.parent / "report.json"
    report.write_text(json.dumps({"checks": [{"check": f"c{i}", "status": s} for i, s in enumerate(statuses)]}))
    assert run(tree, "write", "--check", "verify-pr", "--from-checks", "--into", str(report)).returncode == 0
    m = json.loads(report.read_text())["manifest"]
    assert m["result"] == result
    expected = {"passed": statuses.count("pass"), "failed": statuses.count("fail"),
                "skipped": statuses.count("skip"), "recovered": statuses.count("recovered"),
                "unavailable": statuses.count("unavailable")}
    assert m["counts"] == expected


def test_recovered_by_is_kept_only_with_a_recovered_result(tree):
    rec = json.loads(run(tree, "write", "--check", "c", "--result", "recovered",
                         "--recovered-by", "relaunch second-chance").stdout)
    assert rec["recovered_by"] == ["relaunch", "second-chance"]
    failed = json.loads(run(tree, "write", "--check", "c", "--result", "failed",
                            "--recovered-by", "relaunch").stdout)
    assert "recovered_by" not in failed


# --------------------------------------------------------------------------
# No secrets
# --------------------------------------------------------------------------

SECRETS = {"GITHUB_TOKEN": "ghp_" + "A" * 36, "ADOBE_RMSDK_TOKEN": "s3cr3t-token-value",
           "MATCH_PASSWORD": "hunter2-match", "FIREBASE_TOKEN": "1//firebase-refresh"}


def test_no_environment_secret_reaches_the_manifest(tree):
    r = run(tree, "write", "--check", "c", "--result", "passed", "--udid", UDID,
            env={**SECRETS, "GITHUB_ACTIONS": "true", "ImageOS": "macos15", "ImageVersion": "1.0"})
    assert r.returncode == 0, r.stderr
    for value in SECRETS.values():
        assert value not in r.stdout


def test_every_manifest_value_is_a_plain_identifier(tree):
    r = run(tree, "write", "--check", "c", "--result", "passed", "--udid", UDID)
    leaves = []

    def walk(node):
        if isinstance(node, dict):
            for v in node.values():
                walk(v)
        elif isinstance(node, str):
            leaves.append(node)
    walk(json.loads(r.stdout))
    offenders = [v for v in leaves if re.search(r"[:@=?&]|://", v)]
    assert leaves and not offenders


def test_a_credential_in_a_recorded_input_is_refused_and_not_printed(tree):
    token = "ghp_" + "B" * 36
    write_inputs(tree, repo_name=f"https://x:{token}@github.com/org/repo")
    report = tree.parent / "report.json"
    report.write_text(json.dumps({"checks": []}))
    r = run(tree, "write", "--check", "c", "--result", "passed", "--into", str(report))
    assert r.returncode == 2
    assert "inputs.connector.repo" in r.stderr
    assert token not in r.stdout + r.stderr and "ghp_" not in r.stdout + r.stderr
    assert "manifest" not in json.loads(report.read_text())


# --------------------------------------------------------------------------
# check-stale
# --------------------------------------------------------------------------

def test_a_report_of_the_current_tree_is_current(tree):
    report = write_report(tree)
    r = run(tree, "check-stale", str(report), "--udid", UDID)
    assert r.returncode == 0, r.stdout + r.stderr
    assert r.stdout.startswith("CURRENT:")


def test_a_new_commit_makes_the_report_stale(tree):
    report = write_report(tree)
    (tree / "app.txt").write_text("next\n")
    commit_all(tree, "next")
    r = run(tree, "check-stale", str(report))
    assert r.returncode == 1 and "app.sha" in r.stdout


def test_uncommitted_changes_make_a_clean_report_stale(tree):
    report = write_report(tree)
    (tree / "app.txt").write_text("edited\n")
    r = run(tree, "check-stale", str(report))
    assert r.returncode == 1 and "app.dirty: report False, now True" in r.stdout


@pytest.mark.parametrize("change, field", [
    (lambda t: write_inputs(t, sha256="cd" * 32), "inputs.audioengine.sha256"),
    (lambda t: write_inputs(t, ref="2" * 40), "inputs.connector.sha"),
    (lambda t: write_inputs(t, certs_ref="5" * 40), "inputs.certificates.sha"),
    (lambda t: write_inputs(t, cert_paths=CERT_PATHS + " Certificates/Palace/iOS/APIKeys.json"),
     "inputs.certificates.paths"),
    (lambda t: write_inputs(t, lcp_version="4.2.0"), "inputs.liblcp.version"),
    (lambda t: write_inputs(t, lcp_sha256="01" * 32), "inputs.liblcp.sha256"),
])
def test_a_changed_pinned_input_names_the_input(tree, change, field):
    report = write_report(tree)
    change(tree)
    commit_all(tree, "bump")
    r = run(tree, "check-stale", str(report))
    assert r.returncode == 1 and field in r.stdout


@pytest.mark.parametrize("submodule, field", [
    ("ios-audiobooktoolkit", "inputs.toolkit.recorded_sha"),
    ("ios-audiobook-overdrive", "inputs.overdrive.recorded_sha"),
])
def test_a_submodule_bump_names_the_submodule(tree, submodule, field):
    report = write_report(tree)
    git(tree, "update-index", "--cacheinfo", f"160000,{'3' * 40},{submodule}")
    git(tree, "commit", "-q", "-m", "bump")
    r = run(tree, "check-stale", str(report))
    assert r.returncode == 1 and field in r.stdout


def test_a_different_xcode_is_stale_unless_only_the_tree_is_compared(tree):
    report = write_report(tree)
    r = run(tree, "check-stale", str(report), xcode="Xcode 27.2\nBuild version 27B52\n")
    assert r.returncode == 1 and "toolchain.xcode_build: report 17C529, now 27B52" in r.stdout
    r = run(tree, "check-stale", str(report), "--tree-only", xcode="Xcode 27.2\nBuild version 27B52\n")
    assert r.returncode == 0, r.stdout


def test_an_input_the_report_did_not_record_makes_it_stale(tree):
    report = write_report(tree)
    data = json.loads(report.read_text())
    del data["manifest"]["inputs"]["toolkit"]
    report.write_text(json.dumps(data))
    r = run(tree, "check-stale", str(report))
    assert r.returncode == 1 and "inputs.toolkit: not recorded in the report" in r.stdout


@pytest.mark.parametrize("content", ['{"checks": []}', "not json", '[1, 2]'])
def test_a_report_without_a_usable_manifest_has_no_verdict(tree, content):
    report = tree.parent / "report.json"
    report.write_text(content)
    r = run(tree, "check-stale", str(report))
    assert r.returncode == 3, r.stdout + r.stderr


def test_a_missing_report_has_no_verdict(tree):
    assert run(tree, "check-stale", str(tree.parent / "absent.json")).returncode == 3


# --------------------------------------------------------------------------
# verify-pr.sh writes it into its --report JSON, on both report paths
# --------------------------------------------------------------------------

def _function(source: str, name: str) -> str:
    # The body holds a JSON heredoc whose own closing brace is at column 0.
    m = re.search(rf"^{name}\(\) \{{\n.*?^JSONEOF\n.*?^\}}\n", source, re.S | re.M)
    assert m, f"verify-pr.sh has no {name}()"
    return m.group(0)


def test_verify_pr_report_carries_the_manifest(tree, tmp_path):
    fn = _function(VERIFY_PR.read_text(), "write_report")
    report = tmp_path / "v.json"
    script = f"""
set -euo pipefail
SCRIPT_DIR={REPO / 'scripts'}
REPORT_FILE={report}
SIM_ID={UDID}
PASS_COUNT=1 FAIL_COUNT=0 SKIP_COUNT=1 TEST_PASS=5 TEST_FAIL=0 UNCOMMITTED_COUNT=0
RESULTS=('{{"check":"build","status":"pass","detail":""}}' '{{"check":"mutation","status":"skip","detail":"quick"}}')
BUILD_MANIFEST_ARGS=(--repo-root {tree} --toolchain-config {tree.parent / 'toolchain.ini'}
  --simctl-json {tree.parent / 'simctl.json'} --xcode-version-text {tree.parent / 'xcode.txt'}
  --sdk-version 26.2 --arch arm64)
{fn}
cd {tree}
write_report docs-only
"""
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
    data = json.loads(report.read_text())
    assert data["fast_path"] == "docs-only" and data["pass_count"] == 1
    m = data["manifest"]
    assert (m["check"], m["result"]) == ("verify-pr", "passed")
    assert m["counts"]["skipped"] == 1 and m["toolchain"]["device"] == "iPhone 16 Pro"


def test_verify_pr_writes_every_report_through_one_function():
    source = VERIFY_PR.read_text()
    assert source.count('cat > "$REPORT_FILE"') == 1, "a second report writer would skip the manifest"
    calls = [line.strip() for line in source.splitlines() if re.match(r"\s*write_report\b(?!\(\))", line)]
    assert calls == ["write_report docs-only", "write_report"], calls


# --------------------------------------------------------------------------
# Pull-request CI tests a merge commit; the PR head is recorded beside it
# --------------------------------------------------------------------------

PR_HEAD = "6" * 40
PR_BASE = "7" * 40


def _event(tmp_path: Path, payload) -> dict:
    path = tmp_path / "event.json"
    path.write_text(payload if isinstance(payload, str) else json.dumps(payload))
    return {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_PATH": str(path)}


def _pr_event(head=PR_HEAD, base=PR_BASE):
    return {"pull_request": {"number": 1, "title": "token=abc", "head": {"sha": head, "ref": "x"},
                             "base": {"sha": base}}}


def test_a_pull_request_run_records_the_head_and_base_beside_the_tested_tree(tree):
    r = run(tree, "write", "--check", "c", "--result", "passed", env=_event(tree.parent, _pr_event()))
    assert r.returncode == 0, r.stderr
    app = json.loads(r.stdout)["app"]
    assert app == {"sha": git(tree, "rev-parse", "HEAD"), "dirty": False,
                   "pr_head_sha": PR_HEAD, "pr_base_sha": PR_BASE}
    assert "token=abc" not in r.stdout, "only the two SHAs are taken from the event"


@pytest.mark.parametrize("payload", [
    {"ref": "refs/heads/develop", "after": "8" * 40},          # a push event
    "not json {",                                              # garbled
    {"pull_request": {"head": {"sha": "not-a-sha"}, "base": {"sha": 7}}},
    {"pull_request": "unexpected"},
])
def test_an_event_without_usable_pr_shas_records_none(tree, payload):
    r = run(tree, "write", "--check", "c", "--result", "passed", env=_event(tree.parent, payload))
    assert r.returncode == 0, r.stderr
    app = json.loads(r.stdout)["app"]
    assert "pr_head_sha" not in app and "pr_base_sha" not in app


def test_a_missing_event_file_records_no_pr_shas(tree):
    env = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_PATH": str(tree.parent / "absent.json")}
    r = run(tree, "write", "--check", "c", "--result", "passed", env=env)
    assert r.returncode == 0, r.stderr
    assert "pr_head_sha" not in json.loads(r.stdout)["app"]


def test_the_event_is_read_only_in_ci(tree):
    env = _event(tree.parent, _pr_event())
    env.pop("GITHUB_ACTIONS")
    r = run(tree, "write", "--check", "c", "--result", "passed", env=env)
    assert "pr_head_sha" not in json.loads(r.stdout)["app"]


def _ci_report_tested_on_a_merge(tree) -> tuple[Path, str]:
    """A report as PR CI writes it: app.sha is a merge commit, the PR head is the current HEAD."""
    head = git(tree, "rev-parse", "HEAD")
    report = write_report(tree, env=_event(tree.parent, _pr_event(head=head)))
    data = json.loads(report.read_text())
    data["manifest"]["app"]["sha"] = "9" * 40
    report.write_text(json.dumps(data))
    return report, head


def test_check_stale_is_current_when_head_is_the_pr_head_and_says_so(tree):
    report, head = _ci_report_tested_on_a_merge(tree)
    r = run(tree, "check-stale", str(report))
    assert r.returncode == 0, r.stdout + r.stderr
    assert f"matches this tree at {head[:12]} (app.pr_head_sha)" in r.stdout


def test_check_stale_names_app_sha_when_that_matched(tree):
    report = write_report(tree)
    r = run(tree, "check-stale", str(report))
    assert r.returncode == 0 and "(app.sha)" in r.stdout


def test_a_pr_head_match_still_needs_the_inputs_to_match(tree):
    # The merge commit can carry an input develop moved after the PR branched.
    report, _ = _ci_report_tested_on_a_merge(tree)
    data = json.loads(report.read_text())
    data["manifest"]["inputs"]["audioengine"]["sha256"] = "cd" * 32
    report.write_text(json.dumps(data))
    r = run(tree, "check-stale", str(report))
    assert r.returncode == 1 and "inputs.audioengine.sha256" in r.stdout
    assert "app.sha" not in r.stdout, "the head matched; only the input differs"


def test_a_pr_head_match_still_needs_a_clean_tree(tree):
    report, _ = _ci_report_tested_on_a_merge(tree)
    (tree / "app.txt").write_text("edited\n")
    r = run(tree, "check-stale", str(report))
    assert r.returncode == 1 and "app.dirty" in r.stdout
