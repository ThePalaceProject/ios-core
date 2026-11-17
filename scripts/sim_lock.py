#!/usr/bin/env python3
"""Is a simulator held by another checkout? Shared by palace_mutate.py and
verify-pr.sh so their simulator resolvers apply one rule.

Opt-in: only when PALACE_SIM_LOCK_DIR names a directory of `<UDID>.json` lock
files ({"pid": int, "worktree": path, "lease_until": "YYYY-MM-DDTHH:MM:SSZ" or
null}). Two checkouts testing on one simulator install the same bundle ID and
restart each other's test runners, so a live lock from another checkout refuses.

A lock is live if its pid is alive or its lease has not expired. It is foreign
if the realpath of its worktree is not one of this checkout's roots.

Fail open: a missing, unreadable or malformed lock proceeds; only a clearly
live foreign lock refuses.

prior-art-checked: the lock files are written outside this repo, and nothing in
scripts/ read them before this.

CLI:
  sim_lock.py check UDID --root PATH [--root PATH]   exit 0 free, 3 held (message on stderr)
  sim_lock.py filter --root PATH [--root PATH]       UDIDs on stdin -> the unheld ones on stdout
"""
from __future__ import annotations

import argparse
import calendar
import json
import os
import sys
import time

LOCK_DIR_ENV = "PALACE_SIM_LOCK_DIR"


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _lease_unexpired(lease, now: float) -> bool:
    if not isinstance(lease, str):
        return False
    try:
        return calendar.timegm(time.strptime(lease, "%Y-%m-%dT%H:%M:%SZ")) > now
    except ValueError:
        return False


def foreign_holder(udid: str, roots, lock_dir: str | None = None, now: float | None = None) -> dict | None:
    """The lock record if another checkout holds `udid` live, else None."""
    lock_dir = lock_dir if lock_dir is not None else os.environ.get(LOCK_DIR_ENV)
    if not lock_dir:
        return None
    try:
        with open(os.path.join(lock_dir, f"{udid}.json")) as f:
            lock = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(lock, dict):
        return None
    worktree, pid = lock.get("worktree"), lock.get("pid")
    if not isinstance(worktree, str) or not worktree:
        return None
    if os.path.realpath(worktree) in {os.path.realpath(r) for r in roots}:
        return None
    now = time.time() if now is None else now
    pid_live = isinstance(pid, int) and not isinstance(pid, bool) and _pid_alive(pid)
    if pid_live or _lease_unexpired(lock.get("lease_until"), now):
        return lock
    return None


def describe(udid: str, lock: dict) -> str:
    lease = lock.get("lease_until") or "none"
    return (
        f"simulator {udid} is held by another checkout: {lock.get('worktree')} "
        f"(pid {lock.get('pid')}, lease until {lease}). Wait for that run to "
        "finish, or pick another simulator."
    )


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    check = sub.add_parser("check")
    check.add_argument("udid")
    check.add_argument("--root", action="append", required=True)
    filt = sub.add_parser("filter")
    filt.add_argument("--root", action="append", required=True)
    args = parser.parse_args(argv)

    if args.cmd == "check":
        lock = foreign_holder(args.udid, args.root)
        if lock is None:
            return 0
        sys.stderr.write(f"FATAL: {describe(args.udid, lock)}\n")
        return 3

    for line in sys.stdin:
        udid = line.strip()
        if not udid:
            continue
        lock = foreign_holder(udid, args.root)
        if lock is None:
            print(udid)
        else:
            sys.stderr.write(f"note: skipping {describe(udid, lock)}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
