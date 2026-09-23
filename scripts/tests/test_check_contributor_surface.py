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
