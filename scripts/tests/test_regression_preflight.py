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


def _env_with_stub_simdrive(tmp_path: Path) -> dict:
    """Env whose `python3 -c "import simdrive"` succeeds.

    The campaign entry points require the simdrive package before anything else
    runs. On a machine that has it these tests exercise the real code; on one
    that does not — every CI runner — the script died at that check and the
    assertions below never reached the behaviour they name, so the tests failed
    for a reason unrelated to what they test.

    A stub module makes them hermetic: same path taken everywhere. It does NOT
    weaken anything, because none of these tests exercise simdrive itself; they
    exercise what the script does AFTER confirming it is present.
    """
    stub = tmp_path / "stub-site"
    (stub / "simdrive").mkdir(parents=True, exist_ok=True)
    (stub / "simdrive" / "__init__.py").write_text("", encoding="utf-8")
    env = dict(os.environ)
    env["PYTHONPATH"] = str(stub) + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    return env


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
# chaos pass: a run that never drove the simulator is not a clean pass
# --------------------------------------------------------------------------

def _stub_agent(path: Path, *, open_session_in: Path | None) -> Path:
    """A fake `claude` that writes a summary; optionally simulates driving."""
    body = "#!/usr/bin/env bash\necho 'stub agent summary'\n"
    if open_session_in is not None:
        body += f'mkdir -p "{open_session_in}/session-$RANDOM$$"\n'
    body += "exit 0\n"
    path.write_text(body)
    path.chmod(0o755)
    return path


def _stub_log_bin(path: Path) -> Path:
    """A fake `xcrun` whose `log stream` emits lines, so the live-capture guard
    sees a real capture. A chaos pass now REQUIRES one: findings that quote
    info-level lines are unverifiable once the run ends unless the run captured
    them itself (see test_run_chaos_pass_live_capture.sh)."""
    path.write_text(
        "#!/usr/bin/env bash\n"
        'for a in "$@"; do [ "$a" = "stream" ] && S=1; done\n'
        'if [ "${S:-0}" = "1" ]; then\n'
        "  while true; do echo '2026-01-01 00:00:00.000 I  Palace[1] line'; sleep 0.05; done\n"
        "fi\n"
        "exit 0\n")
    path.chmod(0o755)
    return path


def _run_chaos(tmp_path, sessions: Path, agent: Path):
    runs = tmp_path / "runs"
    runs.mkdir(exist_ok=True)
    env = dict(os.environ,
               CHAOS_SESSIONS_DIR=str(sessions),
               CHAOS_CLAUDE_BIN=str(agent),
               CHAOS_LOG_BIN=str(_stub_log_bin(tmp_path / "xcrun-stub.sh")),
               CHAOS_RUNS_ROOT=str(runs))
    return _run(["bash", str(_CHAOS_PASS),
                 "--udid", FAKE_UDID, "--seed", "cold-launch",
                 "--max-paths", "3", "--max-minutes", "2"],
                cwd=str(_REPO), env=env)


def test_chaos_pass_fails_when_the_agent_never_drove_the_sim(tmp_path):
    """
    The exact 2026-08-20 defect: the agent returns cleanly, writes no findings,
    and never opens a simdrive session because it was denied every tool.
    """
    sessions = tmp_path / "sessions"; sessions.mkdir()
    agent = _stub_agent(tmp_path / "agent-nodrive.sh", open_session_in=None)
    r = _run_chaos(tmp_path, sessions, agent)
    combined = r.stdout + r.stderr
    assert "NO DRIVE" in combined, (
        "a chaos pass that opened no simdrive session did not announce it:\n"
        + combined[-1500:])
    assert r.returncode != 0, "a chaos pass that drove nothing exited 0"


def test_chaos_pass_succeeds_when_the_agent_did_drive_the_sim(tmp_path):
    """
    Clean-path assertion. A real chaos pass legitimately finds nothing sometimes;
    the guard keys on whether a session was opened, never on the finding count,
    so a genuine clean run must not be blocked.
    """
    sessions = tmp_path / "sessions"; sessions.mkdir()
    agent = _stub_agent(tmp_path / "agent-drive.sh", open_session_in=sessions)
    r = _run_chaos(tmp_path, sessions, agent)
    combined = r.stdout + r.stderr
    assert "NO DRIVE" not in combined, (
        "guard false-positives on a pass that DID drive the sim:\n" + combined[-1500:])
    assert r.returncode == 0, f"clean chaos pass exited {r.returncode}:\n{combined[-1500:]}"


# --------------------------------------------------------------------------
# the preflight is a PRECONDITION, not a reminder
# --------------------------------------------------------------------------

@pytest.mark.parametrize("entry", [_AREA_WORKER, _REPO / "scripts" / "regression-chaos-fan.sh"])
def test_campaign_entry_points_invoke_the_preflight(entry):
    """
    The operator must not have to remember to check the chain first. Every
    campaign entry point runs the preflight itself and refuses on failure.
    If this test fails, someone unwired it and a broken chain can once again
    produce a vacuous green.
    """
    body = entry.read_text()
    # The block was extracted into a sourced helper to stop the two copies
    # drifting. The entry point must still ENFORCE it: source the helper and
    # call it. `set -uo pipefail` has no `-e`, so a failed source would not
    # abort — hence the entry point also has to refuse if the helper is gone.
    assert "regression-preflight-precondition.sh" in body, (
        f"{entry.name} no longer sources the precondition helper — a campaign "
        "can start on a chain that cannot test")
    assert "regression_require_preflight" in body, (
        f"{entry.name} sources the helper but never calls it")
    assert "PRECONDITION HELPER MISSING" in body, (
        f"{entry.name} does not refuse when the helper is absent — a missing "
        "helper would silently remove the precondition")

    helper = _REPO / "scripts" / "regression-preflight-precondition.sh"
    hbody = helper.read_text()
    assert "regression-preflight.sh" in hbody, "helper no longer invokes the preflight"
    assert "PREFLIGHT FAILED" in hbody, "helper does not refuse on preflight failure"
    assert "PREFLIGHT MISSING OR NOT EXECUTABLE" in hbody, (
        "helper does not refuse when the preflight itself is absent")


@pytest.mark.parametrize("entry", [_AREA_WORKER, _REPO / "scripts" / "regression-chaos-fan.sh"])
def test_campaign_entry_point_refuses_a_chain_that_cannot_test(tmp_path, entry):
    """Broken chain (sim that does not exist) must stop the campaign, not warn."""
    args = ["bash", str(entry), "--run-dir", str(tmp_path / entry.stem),
            "--sim-id", FAKE_UDID, "--area-group", "catalog"]
    if entry == _AREA_WORKER:
        args += ["--device-cell", "C-pytest", "--no-keychain-reset"]
        args[args.index("catalog")] = "auth"
    else:
        args += ["--dry-run"]
    r = _run(args, cwd=str(_REPO), env=_env_with_stub_simdrive(tmp_path))
    combined = r.stdout + r.stderr
    assert "PREFLIGHT FAILED" in combined, (
        f"{entry.name} ran with an untestable chain:\n" + combined[-1200:])
    assert r.returncode != 0, f"{entry.name} exited 0 on an untestable chain"


@pytest.mark.parametrize("entry", [_AREA_WORKER, _REPO / "scripts" / "regression-chaos-fan.sh"])
def test_entry_point_refuses_when_the_precondition_helper_is_missing(tmp_path, entry):
    """Extracting the block must not recreate the silent skip one level up.

    The scripts run `set -uo pipefail` with no `-e`, so a failed `source` does
    NOT abort. Without an explicit check, deleting the helper would remove the
    precondition and the campaign would proceed — indistinguishable from a
    passing preflight, which is the exact bug the hard-fail was added to kill.

    Runs a COPY of the tree with the helper removed, so the real one is intact.
    """
    # Mirror the repo as a symlink farm so manifest/asset lookups still resolve,
    # then replace scripts/ with a real copy that is missing only the helper.
    root = tmp_path / "repo"
    root.mkdir()
    for entry_path in _REPO.iterdir():
        if entry_path.name != "scripts":
            (root / entry_path.name).symlink_to(entry_path)
    sandbox = root / "scripts"
    sandbox.mkdir()
    for f in (_REPO / "scripts").iterdir():
        if f.is_file():
            shutil.copy2(f, sandbox / f.name)
        elif f.is_dir():
            (sandbox / f.name).symlink_to(f)
    (sandbox / "regression-preflight-precondition.sh").unlink()

    args = ["bash", str(sandbox / entry.name), "--run-dir", str(tmp_path / "run"),
            "--sim-id", FAKE_UDID, "--area-group", "auth"]
    if entry == _AREA_WORKER:
        args += ["--device-cell", "C-pytest", "--no-keychain-reset"]
    else:
        args += ["--dry-run"]
    r = _run(args, cwd=str(root), env=_env_with_stub_simdrive(tmp_path))
    combined = r.stdout + r.stderr
    assert "PRECONDITION HELPER MISSING" in combined, (
        f"{entry.name} ran without the precondition helper:\n" + combined[-1200:])
    assert r.returncode != 0, f"{entry.name} exited 0 with no precondition helper"


@pytest.mark.parametrize("entry", [_AREA_WORKER, _REPO / "scripts" / "regression-chaos-fan.sh"])
def test_entry_point_refuses_when_the_preflight_itself_is_not_executable(tmp_path, entry):
    """The preflight-missing branch must FIRE, not merely exist in the file.

    A string assertion that "PREFLIGHT MISSING OR NOT EXECUTABLE" appears in the
    helper passes even when the branch is unreachable: replacing the condition
    with `if false` left all other tests green, because the banner text is still
    present inside the dead branch. Only driving it catches that.
    """
    root = tmp_path / "repo"
    root.mkdir()
    for entry_path in _REPO.iterdir():
        if entry_path.name != "scripts":
            (root / entry_path.name).symlink_to(entry_path)
    sandbox = root / "scripts"
    sandbox.mkdir()
    for f in (_REPO / "scripts").iterdir():
        if f.is_file():
            shutil.copy2(f, sandbox / f.name)
        elif f.is_dir():
            (sandbox / f.name).symlink_to(f)
    (sandbox / "regression-preflight.sh").chmod(0o644)   # present, not executable

    args = ["bash", str(sandbox / entry.name), "--run-dir", str(tmp_path / "run"),
            "--sim-id", FAKE_UDID, "--area-group", "auth"]
    if entry == _AREA_WORKER:
        args += ["--device-cell", "C-pytest", "--no-keychain-reset"]
    else:
        args += ["--dry-run"]
    r = _run(args, cwd=str(root), env=_env_with_stub_simdrive(tmp_path))
    combined = r.stdout + r.stderr
    assert "PREFLIGHT MISSING OR NOT EXECUTABLE" in combined, (
        f"{entry.name} ran with a non-executable preflight:\n" + combined[-1200:])
    assert r.returncode != 0, f"{entry.name} exited 0 with a non-executable preflight"


def test_preflight_precondition_has_a_documented_bypass():
    """
    A hard precondition needs one deliberate escape hatch (the harness's own
    tests must be able to run without a simulator) — but it must be explicit
    and named, not an accident.
    """
    body = _AREA_WORKER.read_text()
    assert "REGRESSION_SKIP_PREFLIGHT" in body, "no named bypass for harness self-tests"


# --------------------------------------------------------------------------
# the scripts themselves stay syntactically valid
# --------------------------------------------------------------------------

@pytest.mark.parametrize("script", [_PREFLIGHT, _AREA_WORKER, _CHAOS_PASS])
def test_script_parses(script):
    r = _run(["bash", "-n", str(script)])
    assert r.returncode == 0, f"{script.name} fails bash -n:\n{r.stderr}"
