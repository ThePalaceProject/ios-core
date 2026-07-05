#!/usr/bin/env python3
"""
check-unsynchronized-sendable-mock.py — detector for the segv-class of
2026-07-04: a test mock declared `@unchecked Sendable` with unsynchronized
mutable state, driven concurrently by at least one test.

The failure shape (wall entry .forgeos/wall-failures/2026-07-05-sync-mock-race.md):
  1. A mock in PalaceTests/Mocks/ conforms `@unchecked Sendable` (usually
     because the production protocol is Sendable) but guards none of its
     mutable `var` state with a lock/queue/actor.
  2. A test hammers that mock through concurrency primitives
     (DispatchQueue.global / withTaskGroup / Task.detached / concurrentPerform).
  3. The data race corrupts the heap; the segv detonates in a LATER test,
     which gets blamed. The board reads as an unrelated flake.

This detector joins (1) x (2): it flags every `@unchecked Sendable` type in
the mocks directory that has mutable stored state, no synchronization
primitive, AND is referenced in a test file that uses a concurrency
primitive. Latent unsynchronized mocks with no concurrent usage are
reported only with --strict (they are one new test away from the bug).

Usage:
  python3 scripts/check-unsynchronized-sendable-mock.py [--quiet] [--strict] \
      [--mocks-dir PalaceTests/Mocks] [--tests-dir PalaceTests]

Exit codes:
  0 — no active violations
  1 — at least one unsynchronized @unchecked Sendable mock is used concurrently
  2 — argument / IO error
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SYNC_PRIMITIVES = re.compile(
    r"NSLock|NSRecursiveLock|OSAllocatedUnfairLock|os_unfair_lock|"
    r"DispatchQueue\(label|DispatchSemaphore|actor\s|\bMutex\b"
)
CONCURRENCY_PRIMITIVES = re.compile(
    r"DispatchQueue\.global|withTaskGroup|withThrowingTaskGroup|"
    r"Task\.detached|concurrentPerform"
)
UNCHECKED_SENDABLE_DECL = re.compile(
    r"^\s*(?:final\s+)?(?:class|struct)\s+(\w+)[^{\n]*@unchecked Sendable"
)
# Explicit scope-deferral marker: a mock carrying this comment is skipped by
# the blocking join (it stays visible as a note). Format:
#   // unsync-sendable-mock-deferred: <ticket or rationale>
DEFERRAL_MARKER = re.compile(r"//\s*unsync-sendable-mock-deferred:\s*(\S.*)")
MUTABLE_VAR = re.compile(r"^\s*(?:private(?:\(set\))?\s+)?var\s+\w+")
COMPUTED_HINT = re.compile(r"^\s*(?:private(?:\(set\))?\s+)?var\s+\w+[^=\n]*\{\s*$")


def scan_mock_file(path: Path) -> list[str]:
    """Return names of @unchecked Sendable types in `path` that have
    mutable stored state and no synchronization primitive anywhere in the file."""
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    names = []
    for line in lines:
        m = UNCHECKED_SENDABLE_DECL.search(line)
        if m:
            names.append(m.group(1))
    if not names:
        return []
    if SYNC_PRIMITIVES.search(text):
        return []
    # Stored mutable state? (computed-only vars don't count, but a computed
    # var over unlocked storage still needs the storage var, so any stored
    # `var` hit is sufficient signal for a mock file.)
    has_stored_var = any(
        MUTABLE_VAR.match(l) and not COMPUTED_HINT.match(l) for l in lines
    )
    return names if has_stored_var else []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--strict", action="store_true",
                    help="also fail on latent (no concurrent usage) unsynchronized mocks")
    ap.add_argument("--mocks-dir", default="PalaceTests/Mocks")
    ap.add_argument("--tests-dir", default="PalaceTests")
    args = ap.parse_args()

    mocks_dir = Path(args.mocks_dir)
    tests_dir = Path(args.tests_dir)
    if not mocks_dir.is_dir() or not tests_dir.is_dir():
        # Tree-scan semantics: no mocks/tests tree (e.g. the hook fixture's
        # synthetic repo, or a checkout without the test target) = nothing to
        # scan = clean pass. Exiting non-zero here would spuriously block
        # every commit in such a tree — the 2026-06-08 wiring-bug class.
        if not args.quiet:
            print(f"OK: {mocks_dir} or {tests_dir} absent — nothing to scan")
        return 0

    unsynced: dict[str, Path] = {}
    deferred: dict[str, str] = {}
    for mock_file in sorted(mocks_dir.glob("*.swift")):
        names = scan_mock_file(mock_file)
        if not names:
            continue
        marker = DEFERRAL_MARKER.search(
            mock_file.read_text(encoding="utf-8", errors="replace"))
        for name in names:
            if marker:
                deferred[name] = marker.group(1).strip()
            else:
                unsynced[name] = mock_file

    for name, reason in sorted(deferred.items()):
        if not args.quiet:
            print(f"note: {name} deferred ({reason}) — tracked, not blocking")

    if not unsynced:
        if not args.quiet:
            print("OK: no unsynchronized @unchecked Sendable mocks found")
        return 0

    active: list[tuple[str, Path, Path]] = []
    for test_file in sorted(tests_dir.rglob("*.swift")):
        if mocks_dir in test_file.parents:
            continue
        try:
            text = test_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if not CONCURRENCY_PRIMITIVES.search(text):
            continue
        for name, mock_path in unsynced.items():
            if re.search(rf"\b{re.escape(name)}\b", text):
                active.append((name, mock_path, test_file))

    rc = 0
    for name, mock_path, test_file in active:
        print(f"{mock_path}: {name} is @unchecked Sendable with unsynchronized "
              f"mutable state AND used in concurrent test {test_file} — "
              f"lock the mock (see TPPBookRegistryMock) or confine the test")
        rc = 1

    latent = {n: p for n, p in unsynced.items()
              if n not in {a[0] for a in active}}
    for name, mock_path in sorted(latent.items()):
        msg = (f"{mock_path}: {name} is @unchecked Sendable with unsynchronized "
               f"mutable state (latent — no concurrent test usage today)")
        if args.strict:
            print(msg)
            rc = 1
        elif not args.quiet:
            print(f"note: {msg}")

    if rc == 0 and not args.quiet:
        print(f"OK: {len(unsynced)} unsynchronized mock(s), none used concurrently")
    return rc


if __name__ == "__main__":
    sys.exit(main())
