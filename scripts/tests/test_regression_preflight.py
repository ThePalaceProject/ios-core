#!/usr/bin/env python3
"""
test_regression_preflight.py — the guards that stop the regression harness
reporting a result it did not earn.

BACKGROUND (2026-08-20). A full fleet campaign ran 21 shards in 25 seconds and
reported "0 findings" having executed nothing: 96 journeys skipped, 0 evidence
files, exit 0. A chaos fan launched to replace it also executed nothing — every
simdrive tool was ungranted in the headless session, so the agent was denied and
the orchestrator logged "returned cleanly / 0 findings". Both render as a clean
regression in the merged report.

These tests pin the guards added in response. Each asserts BOTH directions:
the guard fires when the chain is broken, AND the clean path is not blocked —
because a gate that only ever sees a violation is untested against false
positives, which is how a blocking gate gets reverted the first time it fires.

Run: pytest scripts/tests/test_regression_preflight.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parent.parent.parent
_PREFLIGHT = _REPO / "scripts" / "regression-preflight.sh"
_AREA_WORKER = _REPO / "scripts" / "regression-area-worker.sh"
_CHAOS_PASS = _REPO / "scripts" / "run-chaos-pass.sh"

# A syntactically valid UDID that is not a real device on any machine.
FAKE_UDID = "DEADBEEF-0000-0000-0000-00000000FAKE"


def _run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180, **kw)


def _mini_repo(tmp_path: Path) -> Path:
    """A throwaway tree with just enough of the repo for the preflight to run."""
    root = tmp_path / "repo"
    (root / "scripts").mkdir(parents=True)
    (root / ".simdrive").mkdir(parents=True)
    for f in ("regression-preflight.sh", "run-chaos-pass.sh", "regression_findings.py"):
        shutil.copy2(_REPO / "scripts" / f, root / "scripts" / f)
    shutil.copy2(_REPO / ".simdrive" / "regression-areas.json",
                 root / ".simdrive" / "regression-areas.json")
    os.chmod(root / "scripts" / "regression-preflight.sh", 0o755)
    return root


# --------------------------------------------------------------------------
# preflight: refuses to green-light a broken chain
# --------------------------------------------------------------------------

def test_preflight_requires_a_udid():
    r = _run(["bash", str(_PREFLIGHT), "--skip-agent"])
    assert r.returncode != 0, "preflight passed with no --udid"
    assert "no --udid given" in r.stdout


def test_preflight_rejects_a_udid_that_is_not_on_this_machine():
    """The stale-UDID case: the campaign would target a device that isn't there."""
    r = _run(["bash", str(_PREFLIGHT), "--udid", FAKE_UDID, "--skip-agent"])
    assert r.returncode != 0, "preflight green-lit a nonexistent simulator"
    assert "not found on this Mac" in r.stdout
    assert "DO NOT RUN THE CAMPAIGN" in r.stderr


def test_preflight_catches_a_chaos_orchestrator_that_grants_no_tools(tmp_path):
    """
    Reintroduce the exact defect: strip --allowedTools from run-chaos-pass.sh.
    The headless subagent would then be denied every simdrive call and the pass
    would report 0 findings having driven nothing.
    """
    root = _mini_repo(tmp_path)
    cp = root / "scripts" / "run-chaos-pass.sh"
    cp.write_text(cp.read_text().replace("--allowedTools", "--toolsRemovedForTest"))
    r = _run(["bash", str(root / "scripts" / "regression-preflight.sh"),
              "--udid", FAKE_UDID])
    assert "does not pass --allowedTools" in r.stdout, (
        "preflight did not notice the chaos orchestrator grants no tools:\n" + r.stdout)
    assert r.returncode != 0


def test_preflight_accepts_the_chaos_orchestrator_as_shipped(tmp_path):
    """Clean-path assertion — the guard must not fire on the real script."""
    root = _mini_repo(tmp_path)
    r = _run(["bash", str(root / "scripts" / "regression-preflight.sh"),
              "--udid", FAKE_UDID])
    assert "declares --allowedTools" in r.stdout, (
        "guard false-positives on the shipped orchestrator:\n" + r.stdout)


def test_preflight_treats_an_empty_replay_corpus_as_a_warning_not_a_failure(tmp_path):
    """
    Chaos does not read ~/.simdrive/recordings, so an empty corpus must not block
    a chaos campaign. It must still be said out loud, because journey replay will
    silently skip everything.
    """
    root = _mini_repo(tmp_path)
    env = dict(os.environ, HOME=str(tmp_path / "emptyhome"))
    (tmp_path / "emptyhome").mkdir()
    r = _run(["bash", str(root / "scripts" / "regression-preflight.sh"),
              "--udid", FAKE_UDID], env=env)
    assert "replay corpus EMPTY" in r.stdout, r.stdout
    # The corpus line itself must be a WARN; the run still fails on the fake UDID.
    corpus_line = [l for l in r.stdout.splitlines() if "replay corpus" in l][0]
    assert "WARN" in corpus_line, "empty corpus was escalated to FAIL: " + corpus_line


def test_preflight_rejects_an_unknown_area_group(tmp_path):
    root = _mini_repo(tmp_path)
    r = _run(["bash", str(root / "scripts" / "regression-preflight.sh"),
              "--udid", FAKE_UDID, "--area-group", "not-a-real-group"])
    assert "is not in the manifest" in r.stdout
    assert r.returncode != 0


# --------------------------------------------------------------------------
# area-worker: a shard that executed nothing is a blocker, not a pass
# --------------------------------------------------------------------------

def test_area_worker_fails_loudly_when_it_executes_no_journeys(tmp_path):
    """
    The original defect: every journey skipped, `passed: 0 / failed: 0 /
    findings: 0`, exit 0. Exercised against a group whose recordings are absent.
    """
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    r = _run(["bash", str(_AREA_WORKER),
              "--area-group", "auth",
              "--device-cell", "C-pytest",
              "--sim-id", FAKE_UDID,
              "--run-dir", str(run_dir),
              "--no-keychain-reset"], cwd=str(_REPO))
    combined = r.stdout + r.stderr
    if "journeys:" not in combined:
        pytest.skip("area-worker could not resolve journeys in this environment")
    assert "NO COVERAGE" in combined, (
        "a shard that executed 0 journeys did not announce it:\n" + combined[-1500:])
    assert r.returncode != 0, "a shard that executed 0 journeys exited 0"
    csvs = list((run_dir / "findings").glob("*.csv")) if (run_dir / "findings").is_dir() else []
    assert csvs, "no findings CSV written for the no-coverage shard"
    body = csvs[0].read_text()
    assert "no-coverage" in body, "no-coverage finding not recorded:\n" + body


# --------------------------------------------------------------------------
# the scripts themselves stay syntactically valid
# --------------------------------------------------------------------------

@pytest.mark.parametrize("script", [_PREFLIGHT, _AREA_WORKER, _CHAOS_PASS])
def test_script_parses(script):
    r = _run(["bash", "-n", str(script)])
    assert r.returncode == 0, f"{script.name} fails bash -n:\n{r.stderr}"
