#!/usr/bin/env python3
"""
Tests for check-doc-references-resolve.py.

The detector exists because documentation kept pointing at scripts and workflows
that had been removed, and one of those dangling pointers was a CI summary
telling reviewers that excluded coverage was "covered by simdrive E2E journeys"
via a workflow that did not exist. So these tests care about two things equally:
that a NEW dangling reference blocks, and that a CLEAN tree passes — a gate that
false-positives gets disabled, and a disabled gate is indistinguishable from a
passing one.
"""

import json
import os
import subprocess
import sys
import textwrap

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
DETECTOR = os.path.join(HERE, "..", "check-doc-references-resolve.py")


def make_repo(tmp_path, docs: dict, scripts=(), workflows=(), baseline=None):
    """A throwaway git repo — the detector enumerates via `git ls-files`."""
    (tmp_path / "scripts").mkdir(parents=True, exist_ok=True)
    (tmp_path / ".github" / "workflows").mkdir(parents=True, exist_ok=True)
    for rel, body in docs.items():
        p = tmp_path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(textwrap.dedent(body), encoding="utf-8")
    for s in scripts:
        (tmp_path / "scripts" / s).write_text("#!/bin/sh\n", encoding="utf-8")
    for w in workflows:
        (tmp_path / ".github" / "workflows" / w).write_text("on: push\n", encoding="utf-8")
    if baseline is not None:
        (tmp_path / "scripts" / "doc-references-baseline.json").write_text(
            json.dumps({"known_dangling": baseline}), encoding="utf-8")

    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "-A"], cwd=tmp_path, check=True)
    return tmp_path


def run(root):
    return subprocess.run(
        [sys.executable, DETECTOR, "--root", str(root)],
        capture_output=True, text=True,
    )


def test_clean_tree_passes(tmp_path):
    """THE PATH THAT MATTERS MOST. A gate that blocks a clean tree gets disabled."""
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Run `scripts/real.sh`, gated by `unit-testing.yml`.\n"},
        scripts=["real.sh"], workflows=["unit-testing.yml"], baseline=[],
    )
    r = run(root)
    assert r.returncode == 0, r.stdout + r.stderr


def test_missing_script_blocks(tmp_path):
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Run `scripts/gone.py` first.\n"},
        baseline=[],
    )
    r = run(root)
    assert r.returncode == 1
    assert "scripts/gone.py" in r.stdout


def test_missing_workflow_blocks(tmp_path):
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Enforced by `ghost-gate.yml` on every PR.\n"},
        baseline=[],
    )
    r = run(root)
    assert r.returncode == 1
    assert "ghost-gate.yml" in r.stdout


def test_harness_prefixed_path_is_not_dangling(tmp_path):
    """`~/harness/...` means deliberately-not-in-this-repo, not a broken link.

    Without this the detector would flag every correct reference to the
    maintainer-local tooling and be worse than useless.
    """
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Run `~/harness/palace-qa/scripts/fan.sh` locally.\n"},
        baseline=[],
    )
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_baselined_reference_is_tolerated(tmp_path):
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Legacy: `scripts/old.py`.\n"},
        baseline=[{"doc": "docs/a.md", "kind": "script", "target": "scripts/old.py"}],
    )
    assert run(root).returncode == 0


def test_new_reference_blocks_even_when_another_is_baselined(tmp_path):
    """The baseline tolerates a backlog; it must not become a blanket amnesty."""
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Legacy `scripts/old.py`, and new `scripts/fresh.py`.\n"},
        baseline=[{"doc": "docs/a.md", "kind": "script", "target": "scripts/old.py"}],
    )
    r = run(root)
    assert r.returncode == 1
    assert "scripts/fresh.py" in r.stdout
    assert "scripts/old.py" not in r.stdout


def test_stale_baseline_entry_blocks(tmp_path):
    """A baseline that outlives the problem silently grows amnesty forever."""
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Run `scripts/fixed.sh`.\n"},
        scripts=["fixed.sh"],
        baseline=[{"doc": "docs/a.md", "kind": "script", "target": "scripts/fixed.sh"}],
    )
    r = run(root)
    assert r.returncode == 1
    assert "now resolve" in r.stdout


def test_archival_directories_are_skipped(tmp_path):
    """`.forgeos/` records what was true then; rewriting it to quiet a linter is worse."""
    root = make_repo(
        tmp_path,
        docs={".forgeos/intent/old.md": "Ran `scripts/long-gone.sh`.\n"},
        baseline=[],
    )
    assert run(root).returncode == 0


def test_real_repo_is_clean(tmp_path):
    """The live tree must pass against its committed baseline."""
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    if not os.path.exists(os.path.join(repo, "scripts", "doc-references-baseline.json")):
        pytest.skip("baseline not present")
    r = subprocess.run([sys.executable, DETECTOR, "--root", repo],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
