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


def test_non_workflow_yaml_that_exists_is_not_dangling(tmp_path):
    """Not every `.yml` in prose is a workflow.

    Resolving yaml names against `.github/workflows/` ALONE reported
    `dependabot.yml`, an orchestrator config, and an atlas manifest as broken
    links — all three tracked and present. A yaml reference is satisfied by that
    basename existing anywhere in the tree.
    """
    root = make_repo(
        tmp_path,
        docs={
            "docs/a.md": "Config in `.github/dependabot.yml` and `tools/x/test-matrix.yml`.\n",
            ".github/dependabot.yml": "version: 2\n",
            "tools/x/test-matrix.yml": "matrix: []\n",
        },
        baseline=[],
    )
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_harness_prefixed_workflow_is_not_dangling(tmp_path):
    """The harness escape must work on the YAML arm too.

    It was implemented only for scripts, so the tool's own printed remedy
    ("write it as ~/harness/...") did not work for a yaml reference.
    """
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Registered in `~/harness/projects/palace-ios.yml`.\n"},
        baseline=[],
    )
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_yaml_that_exists_nowhere_still_blocks(tmp_path):
    """Control for the two above — the relaxation must not blind the arm."""
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Gated by `no-such-gate.yml`.\n"},
        baseline=[],
    )
    r = run(root)
    assert r.returncode == 1
    assert "no-such-gate.yml" in r.stdout


def test_update_baseline_refuses_to_absorb_a_new_finding(tmp_path):
    """The fix for a red run must never be re-running it with a flag.

    Without this, `--update-baseline` is an amnesty button and the gate cannot
    hold: anyone hitting it can make the failure disappear without fixing it.
    """
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Run `scripts/brand-new-gone.py`.\n"},
        baseline=[],
    )
    r = subprocess.run([sys.executable, DETECTOR, "--root", str(root), "--update-baseline"],
                       capture_output=True, text=True)
    assert r.returncode == 1, r.stdout
    assert "Refusing to grow the baseline" in r.stdout
    kept = json.loads((tmp_path / "scripts" / "doc-references-baseline.json").read_text())
    assert kept["known_dangling"] == [], "the baseline was written despite refusing"


def test_update_baseline_grows_only_with_accept_new(tmp_path):
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Run `scripts/brand-new-gone.py`.\n"},
        baseline=[],
    )
    r = subprocess.run(
        [sys.executable, DETECTOR, "--root", str(root), "--update-baseline", "--accept-new"],
        capture_output=True, text=True)
    assert r.returncode == 0, r.stdout
    kept = json.loads((tmp_path / "scripts" / "doc-references-baseline.json").read_text())
    assert len(kept["known_dangling"]) == 1


def test_directory_qualified_yaml_must_resolve_at_that_path(tmp_path):
    """Basename-only matching traded a false-positive class for a false-negative one.

    A doc naming `.github/workflows/test-matrix.yml` passed because an unrelated
    `test-matrix.yml` existed under tools/. When a reference carries a directory
    it names a specific file and must resolve as written.
    """
    root = make_repo(
        tmp_path,
        docs={
            "docs/a.md": "Gated by `.github/workflows/test-matrix.yml`.\n",
            "tools/x/test-matrix.yml": "matrix: []\n",
        },
        baseline=[],
    )
    r = run(root)
    assert r.returncode == 1
    assert ".github/workflows/test-matrix.yml" in r.stdout


def test_dot_slash_prefix_is_stripped_not_lstripped(tmp_path):
    """`./.github/x.yml` must resolve to `.github/x.yml`.

    `str.lstrip("./")` removes a character SET, so it ate the leading dot of
    `.github/` and reported every workflow reference in the repo as missing.
    """
    root = make_repo(
        tmp_path,
        docs={
            "docs/a.md": "See `./.github/workflows/ci.yml`.\n",
            ".github/workflows/ci.yml": "on: push\n",
        },
        baseline=[],
    )
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_url_reference_resolves_by_name(tmp_path):
    """A URL names a file on a server, not a path in this checkout."""
    root = make_repo(
        tmp_path,
        docs={
            "docs/a.md": "See github.com/org/repo/actions/workflows/upload.yml\n",
            ".github/workflows/upload.yml": "on: push\n",
        },
        baseline=[],
    )
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_untracked_script_does_not_satisfy_a_reference(tmp_path):
    """An untracked local file satisfies a reference on the author's machine and
    not in CI — a gate that passes only where it was written."""
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Run `scripts/local-only.sh`.\n"},
        baseline=[],
    )
    # Present on disk but never added to the index.
    (tmp_path / "scripts" / "local-only.sh").write_text("#!/bin/sh\n", encoding="utf-8")
    r = run(root)
    assert r.returncode == 1
    assert "scripts/local-only.sh" in r.stdout


def test_claude_directory_is_scanned(tmp_path):
    """`.claude/skills` and `.claude/agents` are live instructions, not archive."""
    root = make_repo(
        tmp_path,
        docs={".claude/skills/x.md": "Run `scripts/gone.py`.\n"},
        baseline=[],
    )
    r = run(root)
    assert r.returncode == 1
    assert "scripts/gone.py" in r.stdout


def test_claude_worktrees_are_skipped(tmp_path):
    """Sibling checkouts under `.claude/worktrees/` are not this repo's content."""
    root = make_repo(
        tmp_path,
        docs={".claude/worktrees/other/docs/a.md": "Run `scripts/gone.py`.\n"},
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
