#!/usr/bin/env python3
"""The chaos fan must carry run-chaos-pass.sh's NO-DRIVE verdict, not swallow it.

run-chaos-pass.sh exits 4 when a chaos pass never opened a simdrive session —
it explored 0 paths, so its 0 findings prove nothing. The fan invoked it as
`… | sed … || true`, which loses that status twice over: a pipeline reports the
LAST command's status (sed's), and `|| true` discards even that. The area then
reported "ingested 0 chaos finding(s)" and the fan exited 0.

That is the guard-shaped form of the original defect: the signal existed and
nothing carried it. These tests drive the fan with a stub chaos pass so the
propagation is exercised for real, with no simulator involved.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
FAN = REPO / "scripts" / "regression-chaos-fan.sh"

STUB = """#!/usr/bin/env bash
# Stub chaos pass. Exits with $STUB_RC after printing like the real one.
echo "info: stub chaos pass (rc=${STUB_RC:-0})"
exit "${STUB_RC:-0}"
"""


@pytest.fixture
def fan_env(tmp_path: Path):
    """A throwaway repo root holding a COPY of the fan next to a stub chaos pass.

    The fan resolves its siblings from its own location
    (`CHAOS_PASS="$SCRIPT_DIR/run-chaos-pass.sh"`), so the only way to exercise
    the propagation without invoking the real orchestrator is to run a copy from
    a directory where that sibling is the stub. Learned the hard way: an earlier
    version of this test set a CHAOS_PASS env var the fan does not read, and
    launched a real `claude -p` chaos pass.
    """
    root = tmp_path / "repo"
    (root / "scripts").mkdir(parents=True)
    shutil.copy2(FAN, root / "scripts" / FAN.name)
    shutil.copy2(REPO / "scripts" / "regression_findings.py",
                 root / "scripts" / "regression_findings.py")
    (root / ".simdrive").symlink_to(REPO / ".simdrive")

    stub = root / "scripts" / "run-chaos-pass.sh"
    stub.write_text(STUB, encoding="utf-8")
    stub.chmod(0o755)
    # No regression-preflight.sh exists in the copy, so the precondition is
    # inert here; belt and braces via the documented bypass.
    run_dir = tmp_path / "run"
    run_dir.mkdir()

    env = dict(os.environ)
    for k in list(env):
        if k.startswith("GIT_"):
            env.pop(k)
    env["REGRESSION_SKIP_PREFLIGHT"] = "1"
    return env, run_dir, root


def _run_fan(env, run_dir, root, area="auth", **extra_env):
    e = dict(env)
    e.update(extra_env)
    return subprocess.run(
        ["bash", str(root / "scripts" / FAN.name),
         "--area-group", area, "--run-dir", str(run_dir),
         "--sim-id", "STUB-UDID", "--device-cell", "C-test"],
        capture_output=True, text=True, env=e, cwd=str(root), timeout=120)


def test_fan_uses_pipestatus_not_the_pipeline_status():
    """Static half of the contract: `cmd | sed || true` reports sed's status.

    Kept as a text assertion as well as the behavioural tests below, because
    this is the exact line whose reintroduction re-opens the hole.
    """
    text = FAN.read_text(encoding="utf-8")
    assert "PIPESTATUS[0]" in text, \
        "the chaos pass's exit status is not recovered from the pipeline"
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        assert not (stripped.endswith("|| true") and "sed" in stripped), \
            f"the swallowing pipeline is back: {stripped}"


def test_fan_exits_four_when_a_chaos_pass_never_drove(fan_env):
    env, run_dir, root = fan_env
    rc = _run_fan(env, run_dir, root, STUB_RC="4")
    assert rc.returncode == 4, rc.stdout + rc.stderr
    assert "NO DRIVE" in rc.stderr
    assert "regression-preflight.sh" in rc.stderr, \
        "a refusal must name the diagnosis command"


def test_fan_exits_zero_when_the_chaos_pass_drove(fan_env):
    """Clean path. A chaos pass that ran and found nothing is a legitimate pass
    and must not be blocked — the finding count is NOT the discriminator."""
    env, run_dir, root = fan_env
    rc = _run_fan(env, run_dir, root, STUB_RC="0")
    assert rc.returncode == 0, rc.stdout + rc.stderr
    assert "NO DRIVE" not in rc.stderr


def test_other_failures_are_warned_about_but_not_fatal(fan_env):
    """A pass that ran and then errored still produced partial findings worth
    keeping — only 'never drove' is disqualifying."""
    env, run_dir, root = fan_env
    rc = _run_fan(env, run_dir, root, STUB_RC="1")
    assert rc.returncode == 0, rc.stdout + rc.stderr
    assert "exited 1" in rc.stderr


def test_fan_passes_bash_syntax_check():
    rc = subprocess.run(["bash", "-n", str(FAN)], capture_output=True, text=True)
    assert rc.returncode == 0, rc.stderr
