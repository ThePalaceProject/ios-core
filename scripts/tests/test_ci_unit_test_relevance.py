"""Tests for scripts/ci-unit-test-relevance.py — whether a PR must run the unit tests.

prior-art-checked: follows the scripts/tests/ pytest convention for a new script.

A wrong "run" costs one CI run; a wrong "skip" lands an untested change behind a
green check. So the skip side is pinned by its one motivating case (PR #1556:
a different workflow plus tooling files, which ran the full ~50-minute suite)
and every other case pins that the suite RUNS.
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci-unit-test-relevance.py"
spec = importlib.util.spec_from_file_location("ci_unit_test_relevance", SCRIPT)
rel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rel)

RELEVANT = rel.relevant_scripts(REPO)


def _run(paths):
    return rel.classify(paths, RELEVANT)[0]


def test_pr_1556_other_workflow_and_tooling_only_is_skipped():
    assert _run([".github/workflows/tsan.yml", "scripts/tests/test_tsan_lane.py",
                 "scripts/tsan-lane.py", "scripts/tsan-suites.txt"]) is False


def test_docs_and_agent_metadata_only_is_skipped():
    assert _run(["docs/Testing/TESTING_POSTURE.md", "README.md", ".claude/skills/x/SKILL.md",
                 ".forgeos/intent/foo.md", "fastlane/Fastfile", "Gemfile.lock"]) is False


@pytest.mark.parametrize("path", [
    "Palace/Book/TPPBook.swift",
    "PalaceTests/Book/TPPBookTests.swift",
    "Palace/OPDS/TPPOPDSFeed.m",
    "Palace/Packages/PalaceAuth/Sources/PalaceAuth/Token.swift",
    "Palace.xcodeproj/project.pbxproj",
    "Palace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "Palace.xcodeproj/xcshareddata/xcschemes/Palace.xcscheme",
    "ios-audiobooktoolkit",                       # a submodule bump is a gitlink path
    "PalaceConfig/Info.plist",
    "PalaceTests/Fixtures/feed.json",             # test resources
    "Cartfile.resolved",
    "Palace.xcconfig",
    ".github/workflows/unit-testing.yml",          # the workflow itself
    ".github/actions/checkout-adobe/action.yml",
    "scripts/xcode-test-optimized.sh",             # the local mirror of the shard runner
    "some-new-top-level-file.yaml",                # unknown: run rather than guess
])
def test_anything_that_can_change_the_build_or_tests_runs(path):
    assert _run([path]) is True


@pytest.mark.parametrize("script", [
    "scripts/ci-run-test-shard.sh",
    "scripts/ci-test-shards.py",
    "scripts/ci-test-timings.json",
    "scripts/ci-isolated-serial-tests.txt",
    "scripts/ci-unit-test-relevance.py",
    "scripts/setup-repo-drm.sh",
    "scripts/parse-xcresult.py",
    "scripts/triage-corpus-check.sh",
    "scripts/check-objc-witness-nearly-matches.sh",
])
def test_scripts_the_workflow_executes_are_relevant(script):
    assert script in RELEVANT
    assert _run([script]) is True


def test_one_relevant_path_among_skippable_ones_runs():
    assert _run(["docs/a.md", "scripts/tests/test_x.py", "Palace/A.swift"]) is True


def test_an_empty_change_list_runs():
    run, reasons = rel.classify([], RELEVANT)
    assert run is True and reasons


def test_each_path_that_forced_a_run_is_named():
    _, reasons = rel.classify(["docs/a.md", "Palace/A.swift", "Palace/B.swift"], RELEVANT)
    assert len(reasons) == 2 and all(r.startswith("Palace/") for r in reasons)


# --------------------------------------------------------------------------
# The relevant-script closure, on a fixture repo
# --------------------------------------------------------------------------

def _fixture(tmp_path: Path) -> Path:
    (tmp_path / ".github/workflows").mkdir(parents=True)
    (tmp_path / "scripts").mkdir()
    (tmp_path / ".github/workflows/unit-testing.yml").write_text(
        "jobs:\n  t:\n    steps:\n"
        "      # scripts/commented.sh is only mentioned\n"
        "      - run: echo \"run scripts/echoed.sh locally\"\n"
        "      - run: scripts/runner.sh\n")
    (tmp_path / "scripts/runner.sh").write_text(
        "#!/bin/bash\n# see helper-in-comment.py\n\"$(dirname \"$0\")/helper.py\" data.json\n")
    for name in ("commented.sh", "echoed.sh", "helper.py", "helper-in-comment.py",
                 "data.json", "unrelated.py"):
        (tmp_path / "scripts" / name).write_text("print('x')\n")
    return tmp_path


def test_closure_follows_executed_references_transitively(tmp_path):
    found = rel.relevant_scripts(_fixture(tmp_path))
    assert {"scripts/runner.sh", "scripts/helper.py", "scripts/data.json"} <= found


def test_closure_ignores_comments_and_printed_text(tmp_path):
    found = rel.relevant_scripts(_fixture(tmp_path))
    assert not found & {"scripts/commented.sh", "scripts/echoed.sh",
                        "scripts/helper-in-comment.py", "scripts/unrelated.py"}


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def test_cli_writes_the_decision_to_github_output(tmp_path):
    changed = tmp_path / "changed.txt"
    changed.write_text(".github/workflows/tsan.yml\nscripts/tsan-lane.py\n")
    out = tmp_path / "out"
    r = subprocess.run([sys.executable, str(SCRIPT), "--changed", str(changed), "--github-output"],
                       capture_output=True, text=True, env={**os.environ, "GITHUB_OUTPUT": str(out)})
    assert r.returncode == 0, r.stdout + r.stderr
    assert out.read_text() == "run=false\n"

    changed.write_text("Palace/A.swift\n")
    out.write_text("")
    subprocess.run([sys.executable, str(SCRIPT), "--changed", str(changed), "--github-output"],
                   capture_output=True, text=True, env={**os.environ, "GITHUB_OUTPUT": str(out)})
    assert out.read_text() == "run=true\n"


def test_cli_refuses_github_output_without_the_variable(tmp_path):
    changed = tmp_path / "changed.txt"
    changed.write_text("Palace/A.swift\n")
    env = {k: v for k, v in os.environ.items() if k != "GITHUB_OUTPUT"}
    r = subprocess.run([sys.executable, str(SCRIPT), "--changed", str(changed), "--github-output"],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 1
