"""Simulator lock files: palace_mutate.py and verify-pr.sh must not run tests on
a simulator another checkout holds.

Two checkouts that install the same app bundle ID on one simulator restart each
other's test runners and mix their results (measured 2026-09-30: five runner
restarts in one mutation run). When PALACE_SIM_LOCK_DIR names a directory of
`<UDID>.json` lock files, both resolvers consult it. Unset, nothing changes.

Rule under test: a lock is live if its pid is alive OR its lease has not
expired; a live lock whose worktree is not this checkout refuses; a missing or
malformed lock proceeds.

prior-art-checked: the lock files are written outside this repo; nothing in
scripts/ read them before, and the two resolvers share one reader here.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

_SCRIPTS = Path(__file__).resolve().parents[1]
_REPO_ROOT = _SCRIPTS.parent
sys.path.insert(0, str(_SCRIPTS))
import palace_mutate as pm  # noqa: E402

FIRST = "AAAAAAAA-1111-2222-3333-444444444444"
SECOND = "CCCCCCCC-1111-2222-3333-444444444444"
AVAILABLE = textwrap.dedent(
    f"""\
    == Devices ==
    -- iOS 26.0 --
        iPhone 16 Pro ({FIRST}) (Booted)
        iPhone 17 Pro ({SECOND}) (Shutdown)
    """
)
OTHER_CHECKOUT = "/tmp/some-other-checkout"


def _iso(offset_seconds: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + offset_seconds))


def _dead_pid() -> int:
    proc = subprocess.Popen(["true"])
    proc.wait()
    return proc.pid


def _write_lock(lock_dir: Path, udid: str, *, pid: int, worktree: str, lease_until=None):
    lock_dir.mkdir(parents=True, exist_ok=True)
    (lock_dir / f"{udid}.json").write_text(json.dumps({
        "udid": udid, "pid": pid, "worktree": worktree,
        "claimed_at": _iso(-60), "branch": "develop", "lease_until": lease_until,
    }))


@pytest.fixture
def lock_dir(tmp_path, monkeypatch):
    d = tmp_path / "locks"
    d.mkdir()
    monkeypatch.setenv("PALACE_SIM_LOCK_DIR", str(d))
    return d


@pytest.fixture
def mutate_env(monkeypatch):
    """palace_mutate with a stubbed device list and no memoized result."""
    monkeypatch.setattr(pm, "_RESOLVED_SIM_ID", None)
    monkeypatch.setattr(pm, "simctl_available_devices", lambda: AVAILABLE)
    monkeypatch.setenv("HARNESS_SESSION_SIM_UDID", FIRST)


# ------------------------------------------------------------ palace_mutate

def test_noLockDirVariable_lockFileIsIgnored(tmp_path, monkeypatch, mutate_env):
    monkeypatch.delenv("PALACE_SIM_LOCK_DIR", raising=False)
    _write_lock(tmp_path / "locks", FIRST, pid=os.getppid(), worktree=OTHER_CHECKOUT)
    assert pm.require_sim_id() == FIRST


def test_lockDirWithNoLockFile_proceeds(lock_dir, mutate_env):
    assert pm.require_sim_id() == FIRST


def test_liveForeignLock_refusesWithExitTwoNamingTheHolder(lock_dir, mutate_env, capsys):
    _write_lock(lock_dir, FIRST, pid=os.getppid(), worktree=OTHER_CHECKOUT)
    with pytest.raises(SystemExit) as exc:
        pm.require_sim_id()
    assert exc.value.code == 2
    err = capsys.readouterr().err
    assert FIRST in err
    assert OTHER_CHECKOUT in err
    assert str(os.getppid()) in err


def test_lockHeldByThisCheckout_proceeds(lock_dir, mutate_env):
    _write_lock(lock_dir, FIRST, pid=os.getppid(), worktree=str(_REPO_ROOT))
    assert pm.require_sim_id() == FIRST


def test_lockHeldByThisCheckoutViaSymlink_proceeds(tmp_path, lock_dir, mutate_env):
    link = tmp_path / "alias"
    link.symlink_to(_REPO_ROOT)
    _write_lock(lock_dir, FIRST, pid=os.getppid(), worktree=str(link))
    assert pm.require_sim_id() == FIRST


def test_deadPidExpiredLease_proceeds(lock_dir, mutate_env):
    _write_lock(lock_dir, FIRST, pid=_dead_pid(), worktree=OTHER_CHECKOUT, lease_until=_iso(-600))
    assert pm.require_sim_id() == FIRST


def test_deadPidNoLease_proceeds(lock_dir, mutate_env):
    _write_lock(lock_dir, FIRST, pid=_dead_pid(), worktree=OTHER_CHECKOUT)
    assert pm.require_sim_id() == FIRST


def test_deadPidUnexpiredLease_refuses(lock_dir, mutate_env):
    _write_lock(lock_dir, FIRST, pid=_dead_pid(), worktree=OTHER_CHECKOUT, lease_until=_iso(3600))
    with pytest.raises(SystemExit) as exc:
        pm.require_sim_id()
    assert exc.value.code == 2


@pytest.mark.parametrize("body", ["{not json", "", "[]", '{"pid": "abc", "worktree": 7}'])
def test_malformedLock_proceeds(lock_dir, mutate_env, body):
    (lock_dir / f"{FIRST}.json").write_text(body)
    assert pm.require_sim_id() == FIRST


def test_fallbackScan_skipsTheLockedSimulator(lock_dir, mutate_env, monkeypatch):
    monkeypatch.setenv("HARNESS_SESSION_SIM_UDID", "DEADBEEF-0000-0000-0000-000000000000")
    _write_lock(lock_dir, FIRST, pid=os.getppid(), worktree=OTHER_CHECKOUT)
    assert pm.require_sim_id() == SECOND


def test_fallbackScan_everyIPhoneLocked_exitsTwo(lock_dir, mutate_env, monkeypatch):
    monkeypatch.setenv("HARNESS_SESSION_SIM_UDID", "DEADBEEF-0000-0000-0000-000000000000")
    for udid in (FIRST, SECOND):
        _write_lock(lock_dir, udid, pid=os.getppid(), worktree=OTHER_CHECKOUT)
    with pytest.raises(SystemExit) as exc:
        pm.require_sim_id()
    assert exc.value.code == 2


# ---------------------------------------------------------------- verify-pr

def _run_verify_pr_selection(want: str, lock_dir: Path | None) -> subprocess.CompletedProcess:
    """Run verify-pr.sh's whole simulator-selection block against a stub list."""
    source = (_SCRIPTS / "verify-pr.sh").read_text()
    start = source.index('SIM_LOCK_HELPER="$SCRIPT_DIR/sim_lock.py"')
    end = source.index("while [[ $# -gt 0 ]]; do", start)
    program = 'xcrun() { printf \'%s\' "$STUB_OUTPUT"; }\n' + source[start:end] + '\necho "SIM=$SIM_ID"\n'
    env = {
        "PATH": os.environ["PATH"],
        "STUB_OUTPUT": AVAILABLE,
        "SCRIPT_DIR": str(_SCRIPTS),
        "REPO_ROOT": str(_REPO_ROOT),
        "HARNESS_SESSION_SIM_UDID": want,
    }
    if lock_dir is not None:
        env["PALACE_SIM_LOCK_DIR"] = str(lock_dir)
    return subprocess.run(["bash", "-c", program], capture_output=True, text=True, env=env)


def test_verifyPr_noLockDirVariable_unchanged(tmp_path):
    _write_lock(tmp_path, FIRST, pid=os.getppid(), worktree=OTHER_CHECKOUT)
    out = _run_verify_pr_selection(FIRST, None)
    assert out.returncode == 0, out.stderr
    assert "SIM=" + FIRST in out.stdout


def test_verifyPr_liveForeignLockOnWantedSim_exitsTwo(tmp_path):
    _write_lock(tmp_path, FIRST, pid=os.getppid(), worktree=OTHER_CHECKOUT)
    out = _run_verify_pr_selection(FIRST, tmp_path)
    assert out.returncode == 2
    assert OTHER_CHECKOUT in out.stderr
    assert "SIM=" not in out.stdout


def test_verifyPr_ownLock_proceeds(tmp_path):
    _write_lock(tmp_path, FIRST, pid=os.getppid(), worktree=str(_REPO_ROOT))
    out = _run_verify_pr_selection(FIRST, tmp_path)
    assert out.returncode == 0, out.stderr
    assert "SIM=" + FIRST in out.stdout


def test_verifyPr_fallbackScan_skipsTheLockedSimulator(tmp_path):
    _write_lock(tmp_path, FIRST, pid=os.getppid(), worktree=OTHER_CHECKOUT)
    out = _run_verify_pr_selection("DEADBEEF-0000-0000-0000-000000000000", tmp_path)
    assert out.returncode == 0, out.stderr
    assert "SIM=" + SECOND in out.stdout


# ------------------------------------------------------------ helper itself

def test_helperCli_filter_dropsOnlyForeignLiveLocks(lock_dir):
    _write_lock(lock_dir, FIRST, pid=os.getppid(), worktree=OTHER_CHECKOUT)
    out = subprocess.run(
        [sys.executable, str(_SCRIPTS / "sim_lock.py"), "filter", "--root", str(_REPO_ROOT)],
        input=f"{FIRST}\n{SECOND}\n", capture_output=True, text=True,
    )
    assert out.returncode == 0
    assert out.stdout.split() == [SECOND]


def test_foreignHolder_malformedLease_fallsBackToPid(lock_dir):
    import sim_lock

    _write_lock(lock_dir, FIRST, pid=_dead_pid(), worktree=OTHER_CHECKOUT, lease_until="tomorrow")
    assert sim_lock.foreign_holder(FIRST, [str(_REPO_ROOT)]) is None
