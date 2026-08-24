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


def make_repo(tmp_path, docs: dict, scripts=(), workflows=(), baseline=None,
              gitignore=()):
    """A throwaway git repo — the detector enumerates via `git ls-files`."""
    (tmp_path / "scripts").mkdir(parents=True, exist_ok=True)
    if gitignore:
        (tmp_path / ".gitignore").write_text(
            "\n".join(gitignore) + "\n", encoding="utf-8")
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


# ---------------------------------------------------------------------------
# The SOURCE arm. Added when the decomposition waves moved files into
# Palace/Packages/* and left 37 doc pointers aimed at addresses that no longer
# existed. Same two things matter as above: a NEW dead path blocks, and the
# legitimate reasons a path is absent do NOT block — because the three exempt
# classes here (ellipsis, deliberately-untracked secret, documented placeholder)
# are all common enough that a false positive on any of them would get the whole
# gate switched off.
# ---------------------------------------------------------------------------


def make_src_repo(tmp_path, docs: dict, sources=(), baseline=None):
    for rel, body in docs.items():
        p = tmp_path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(textwrap.dedent(body), encoding="utf-8")
    for s in sources:
        p = tmp_path / s
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("// swift\n", encoding="utf-8")
    (tmp_path / "scripts").mkdir(parents=True, exist_ok=True)
    (tmp_path / "scripts" / "doc-references-baseline.json").write_text(
        json.dumps({"known_dangling": baseline or []}), encoding="utf-8")
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "-A"], cwd=tmp_path, check=True)
    return tmp_path


def test_existing_source_path_passes(tmp_path):
    """The clean path, again: a doc naming a real file must not block."""
    root = make_src_repo(
        tmp_path,
        docs={"docs/a.md": "See `Palace/Network/Executor.swift` for the retry.\n"},
        sources=["Palace/Network/Executor.swift"])
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_missing_source_path_blocks(tmp_path):
    """The defect this arm exists for: a pointer at a file that moved away."""
    root = make_src_repo(
        tmp_path,
        docs={"docs/a.md": "See `Palace/Book/Models/TPPBookRegistry.swift`.\n"})
    r = run(root)
    assert r.returncode == 1
    assert "TPPBookRegistry.swift" in r.stdout
    assert "source" in r.stdout


def test_ellipsis_path_is_not_dangling(tmp_path):
    """`Palace/Reader2/.../LicensesService.swift` abbreviates a path rather than
    claiming one. Docs use this constantly; flagging it would bury the real
    findings under noise and the gate would be turned off."""
    root = make_src_repo(
        tmp_path,
        docs={"docs/a.md": "See `Palace/Reader2/.../LicensesService.swift`.\n"})
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_deliberately_untracked_secret_is_not_dangling(tmp_path):
    """APIKeys.swift is never committed by repo rule (CLAUDE.md "Secrets"), so
    its absence is the rule working. Flagging it would pressure someone to
    "fix" the gate by committing the secret."""
    root = make_src_repo(
        tmp_path,
        docs={"docs/a.md": "Provide `Palace/AppInfrastructure/APIKeys.swift` locally.\n"})
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_documented_placeholder_is_not_dangling(tmp_path):
    """`Palace/Path/ChangedFile.swift` in a usage example teaches the shape of a
    command; it is not a claim that the file exists."""
    root = make_src_repo(
        tmp_path,
        docs={"docs/a.md": "    palace_mutate.py --file Palace/Path/ChangedFile.swift\n"})
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_placeholder_exemption_does_not_leak_to_a_real_sibling(tmp_path):
    """The exemption is a set of exact literals, not a prefix or a heuristic on
    the segment name. If it matched "anything under Palace/Path/", a real file
    added there later would become permanently unguarded."""
    root = make_src_repo(
        tmp_path,
        docs={"docs/a.md": "See `Palace/Path/RealFile.swift`.\n"})
    r = run(root)
    assert r.returncode == 1, r.stdout
    assert "RealFile.swift" in r.stdout


def test_source_fixtures_directory_is_skipped(tmp_path):
    """scripts/_fixtures/ is detector INPUT: its paths are deliberately fake."""
    root = make_src_repo(
        tmp_path,
        docs={"scripts/_fixtures/m1/intent.md": "- Palace/SomeOther/Fake.swift\n"})
    r = run(root)
    assert r.returncode == 0, r.stdout


def test_baselined_source_entry_is_tolerated_but_a_new_one_still_blocks(tmp_path):
    """The amnesty is per-reference, not per-kind — baselining the backlog must
    not switch the source arm off."""
    root = make_src_repo(
        tmp_path,
        docs={"docs/a.md": "`Palace/Old/Gone.swift` and `Palace/New/AlsoGone.swift`\n"},
        baseline=[{"doc": "docs/a.md", "kind": "source",
                   "target": "Palace/Old/Gone.swift"}])
    r = run(root)
    assert r.returncode == 1, r.stdout
    assert "AlsoGone.swift" in r.stdout
    assert "Old/Gone.swift" not in r.stdout.split("Baseline entries")[0]


def test_real_repo_is_clean(tmp_path):
    """The live tree must pass against its committed baseline."""
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    if not os.path.exists(os.path.join(repo, "scripts", "doc-references-baseline.json")):
        pytest.skip("baseline not present")
    r = subprocess.run([sys.executable, DETECTOR, "--root", repo],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


# ---------------------------------------------------------------------------
# Targets the repo's own ignore rules deny.
#
# The swarm archive was removed and `.forgeos/swarms/` added to .gitignore on
# 2026-08-24. Nothing about the DOCS changed, but four references went dangling
# the moment the archive stopped being tracked — because a bare `manifest.yaml`
# in an ASCII layout diagram had been resolving, by basename, against archived
# files that happened to carry that name.
#
# Those references are not drift. `.forgeos/swarms/` is written at RUN TIME by
# the swarm skill into a directory git is told to ignore, so no tracked file can
# ever satisfy them. That is the same category the detector already spells out
# for APIKeys.swift: absence is the rule working. Baselining them instead would
# file a permanent exemption under "pre-existing drift to fix one day", which is
# the one thing the baseline is documented not to accept.
# ---------------------------------------------------------------------------


def test_runtime_artifact_target_with_directory_is_not_dangling(tmp_path):
    """A path the repo's own ignore rules deny cannot be a broken pointer."""
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": """
            Set `.forgeos/swarms/swarm_afec67f0/manifest.yaml` to `complete`.
            """},
        baseline=[], gitignore=[".forgeos/swarms/"],
    )
    r = run(root)
    assert r.returncode == 0, r.stdout + r.stderr


def test_runtime_artifact_bare_name_is_not_dangling(tmp_path):
    """The layout-diagram form, which carries no directory to check-ignore."""
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": """
            ```
            .forgeos/swarms/<swarm_id>/
            \u251c\u2500\u2500 manifest.yaml   # machine-readable state
            ```
            The `status` field in manifest.yaml progresses triaged -> complete.
            """},
        baseline=[], gitignore=[".forgeos/swarms/"],
    )
    r = run(root)
    assert r.returncode == 0, r.stdout + r.stderr


def test_dangling_workflow_still_blocks_when_nothing_ignores_it(tmp_path):
    """CONTROL. The exemption must cover only what the ignore rules cover.

    Without this, a fix for the four findings above is indistinguishable from
    switching the workflow arm off — which is the failure the module docstring
    exists to prevent."""
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Gated by `nightly-soak.yml`, see .github/workflows.\n"},
        baseline=[], gitignore=[".forgeos/swarms/"],
    )
    r = run(root)
    assert r.returncode == 1, "a genuinely missing workflow must still block"
    assert "nightly-soak.yml" in r.stdout


def test_ignore_exemption_does_not_swallow_other_forgeos_targets(tmp_path):
    """CONTROL. `.forgeos/intent/` is live and tracked; only swarms/ is denied."""
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "See `.forgeos/intent/pp-1234.yaml` for the contract.\n"},
        baseline=[], gitignore=[".forgeos/swarms/"],
    )
    r = run(root)
    assert r.returncode == 1, "a non-ignored .forgeos target must still block"
    assert "pp-1234.yaml" in r.stdout


def test_gitignored_but_EXTRACTED_script_still_blocks(tmp_path):
    """THE REGRESSION THIS NEARLY SHIPPED.

    A first cut exempted anything `git check-ignore` called ignored. That reads
    as principled and quietly switches the detector off: the scripts extracted to
    the maintainer-local harness are gitignored too, so every doc still pointing
    at `scripts/regression-report.sh` — the exact rot this gate was built for —
    would have gone silent. Ignored means "not tracked here", which covers the
    artifact written tomorrow AND the script deleted yesterday. Only the first is
    compliance, so the exemption is a path prefix and not an ignore query.
    """
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "Generate it with `scripts/regression-report.sh`.\n"},
        baseline=[], gitignore=["scripts/regression-report.sh", ".forgeos/swarms/"],
    )
    r = run(root)
    assert r.returncode == 1, "an extracted-but-gitignored script must still block"
    assert "regression-report.sh" in r.stdout


def test_gitignored_but_EXTRACTED_workflow_still_blocks(tmp_path):
    """Same trap on the workflow arm, where the first cut also applied it."""
    root = make_repo(
        tmp_path,
        docs={"docs/a.md": "The atlas runs from `tools/ledger/codeatlas.yml`.\n"},
        baseline=[], gitignore=["tools/ledger/codeatlas.yml", ".forgeos/swarms/"],
    )
    r = run(root)
    assert r.returncode == 1, "an extracted-but-gitignored workflow must still block"
    assert "codeatlas.yml" in r.stdout
