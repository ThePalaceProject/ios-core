"""Tests for scripts/check-contributor-surface.py.

Covers both checks in both directions — the clean path must pass (a gate that
only ever sees a violation can hide a wiring bug that blocks everything) and the
violation path must fail with a useful message.
"""
import importlib.util
import json
from pathlib import Path

_MOD_PATH = Path(__file__).resolve().parent.parent / "check-contributor-surface.py"
_spec = importlib.util.spec_from_file_location("check_contributor_surface", _MOD_PATH)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)


# ---- CHECK A: private-tooling leak guard over docs -------------------------

def test_clean_doc_passes(tmp_path):
    doc = tmp_path / "CLAUDE.md"
    doc.write_text(
        "# Palace iOS Core\n"
        "Run `scripts/verify-pr.sh --quick` before opening a PR.\n"
        "Architecture lives in docs/architecture/.\n"
    )
    assert mod.check_docs([doc]) == []


def test_forgeos_reference_is_flagged(tmp_path):
    doc = tmp_path / "CLAUDE.md"
    doc.write_text("Run the ForgeOS governance gates before promote.\n")
    v = mod.check_docs([doc])
    assert len(v) == 1 and "ForgeOS" in v[0]


def test_each_private_marker_is_flagged(tmp_path):
    doc = tmp_path / "CLAUDE.md"
    lines = [
        "see ~/harness/bin for the CLI",
        "drive it with mcp__simdrive__tap",
        "use /swarm for multi-module work",
        "canon lives in .forgeos/reviewer-refs/",
        "export FORGEOS_API_KEY=xyz",
        "flows under .simdrive/journeys/",
        "SpecterQA is deprecated",
    ]
    doc.write_text("\n".join(lines) + "\n")
    # every line trips exactly one finding
    assert len(mod.check_docs([doc])) == len(lines)


def test_leak_ok_marker_suppresses(tmp_path):
    doc = tmp_path / "CLAUDE.md"
    doc.write_text(
        "Contributors without the harness can ignore it. <!-- leak-ok: opt-in boundary -->\n"
    )
    assert mod.check_docs([doc]) == []


def test_missing_doc_is_not_a_violation(tmp_path):
    assert mod.check_docs([tmp_path / "does-not-exist.md"]) == []


# ---- CHECK B: clean-clone hook safety --------------------------------------

def _write_settings(tmp_path, command):
    p = tmp_path / "settings.json"
    p.write_text(json.dumps({
        "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": command}
        ]}]}
    }))
    return p


def test_empty_committed_settings_passes(tmp_path):
    # {} — no hooks in the committed file; the clean, correct state
    p = tmp_path / "settings.json"
    p.write_text("{}")
    assert mod.check_settings(p) == []


def test_guarded_hook_in_committed_is_still_flagged(tmp_path):
    # even guarded, a scripts/hooks/ ref does not belong in the committed file
    p = _write_settings(
        tmp_path,
        "[ -e scripts/hooks/pre-commit-check.sh ] || exit 0; bash scripts/hooks/pre-commit-check.sh",
    )
    v = mod.check_settings(p)
    assert len(v) == 1 and "settings.local.json" in v[0]


def test_unguarded_hook_is_flagged(tmp_path):
    p = _write_settings(tmp_path, "bash scripts/hooks/pre-commit-check.sh")
    v = mod.check_settings(p)
    assert len(v) == 1 and "scripts/hooks/" in v[0]


def test_or_true_hook_in_committed_is_flagged(tmp_path):
    # references scripts/hooks/ → belongs in settings.local.json regardless of guard
    p = _write_settings(
        tmp_path,
        "jq -r '.x' | grep -q y && bash scripts/hooks/gate.sh || true",
    )
    v = mod.check_settings(p)
    assert len(v) == 1 and "scripts/hooks/" in v[0]


def test_non_hooks_dir_command_is_ignored(tmp_path):
    # a tracked, always-present script (not under scripts/hooks/) is fine committed
    p = _write_settings(tmp_path, "bash scripts/pre-commit-phase35-detectors.sh")
    assert mod.check_settings(p) == []


def test_missing_settings_is_not_a_violation(tmp_path):
    assert mod.check_settings(tmp_path / "nope.json") == []


def test_invalid_json_is_flagged(tmp_path):
    p = tmp_path / "settings.json"
    p.write_text("{not json")
    v = mod.check_settings(p)
    assert len(v) == 1 and "not valid JSON" in v[0]


# ---- CHECK C: private-tooling leak guard over TRACKED skills and agents ----
#
# CHECK A guards what a contributor READS. CHECK C guards what a contributor's
# agent EXECUTES, which is strictly worse when it leaks: a skill is markdown and
# cannot `command -v` its way out, so a missing ForgeOS MCP tool is discovered
# partway through a run, after the tokens are spent (PP-5234).
#
# Both directions are asserted. The clean paths matter as much as the firing
# one: CHECK C enumerates via `git ls-files`, so a wiring bug would either scan
# nothing (silent pass forever) or scan untracked maintainer files (blocking
# every local run).

import subprocess


def _git_repo(tmp_path):
    """A real git repo — CHECK C enumerates via `git ls-files`, not a glob."""
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "t@e.st"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "t"], check=True)
    return tmp_path


def _add(root, rel, text):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    subprocess.run(["git", "-C", str(root), "add", "-f", rel], check=True)
    return p


def test_clean_tracked_skill_passes(tmp_path):
    root = _git_repo(tmp_path)
    _add(root, ".claude/skills/clean-code/SKILL.md",
         "Audit the diff for duplication and dead code.\n"
         "Run `scripts/verify-pr.sh --quick` before opening a PR.\n")
    assert mod.check_agent_surface(root) == []


def test_tracked_skill_spawning_private_agent_is_flagged(tmp_path):
    root = _git_repo(tmp_path)
    _add(root, ".claude/skills/clean-code/SKILL.md",
         "Spawn the forge-architect-reviewer agent for an advisory pass.\n")
    v = mod.check_agent_surface(root)
    assert len(v) == 1, v
    assert ".claude/skills/clean-code/SKILL.md:1" in v[0]


def test_tracked_skill_calling_forgeos_mcp_is_flagged(tmp_path):
    root = _git_repo(tmp_path)
    _add(root, ".claude/skills/swarm/SKILL.md",
         "Register via mcp__forgeos__forge_propose_changeset before coding.\n")
    assert len(mod.check_agent_surface(root)) == 1


def test_tracked_agent_definition_is_flagged(tmp_path):
    root = _git_repo(tmp_path)
    _add(root, ".claude/agents/some-reviewer.md",
         "Submit the verdict with mcp__forgeos__forge_submit_review.\n")
    assert len(mod.check_agent_surface(root)) == 1


def test_untracked_private_skill_is_invisible(tmp_path):
    """The maintainer's own git-ignored skills must NOT trip the gate.

    This is the arrangement the fix depends on: private skills live on disk but
    outside git. If CHECK C scanned the filesystem instead of the index, every
    maintainer run would fail and the gate would be disabled within a day.
    """
    root = _git_repo(tmp_path)
    p = root / ".claude/skills/rigorous-fix/SKILL.md"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("Use mcp__forgeos__forge_check_gates and spawn forge-qa-reviewer.\n")
    # deliberately NOT git-added
    assert mod.check_agent_surface(root) == []


def test_leak_ok_suppresses_in_skills_too(tmp_path):
    root = _git_repo(tmp_path)
    _add(root, ".claude/skills/clean-code/SKILL.md",
         "See `.forgeos/wall-failures/` <!-- leak-ok: tracked in this repo -->\n")
    assert mod.check_agent_surface(root) == []


def test_no_skills_dir_is_not_a_violation(tmp_path):
    root = _git_repo(tmp_path)
    _add(root, "README.md", "hello\n")
    assert mod.check_agent_surface(root) == []


def test_non_git_dir_makes_no_claim(tmp_path):
    """Absence of git must not render as a pass — that is the shape where a
    gate reports success because it could not run at all."""
    v = mod.check_agent_surface(tmp_path / "not-a-repo")
    assert v and "could not enumerate" in v[0]
