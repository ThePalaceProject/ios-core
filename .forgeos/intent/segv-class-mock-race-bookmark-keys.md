---
name: segv-class-mock-race-bookmark-keys
created: 2026-07-05
author: claude-fable-5
type: bugfix
---

## Summary

Two Heka-dogfood-sourced fixes in the Reader2 bookmark/position-sync surface,
one PR (same subsystem): (1) the 2026-07-04 full-suite SIGSEGV in
`TPPLastReadPositionSynchronizer_ConcurrencyTests` — root-caused to
`TPPBookRegistryMock` racing under concurrent test load, NOT to production
code; (2) the STATE.SplitBrain finding — bookmark wire-format JSON keys
defined independently in two files, a silent round-trip-breaking drift risk.

## Reproduction

`harness test` 2026-07-04 (full Palace scheme, sim iPhone 17 Pro):
`testMultipleSynchronizersWithSameRegistry_DoNotConflict()` — "Test crashed
with signal segv", 7479/7492 passed otherwise. Same SHA (52413d290) passed
7486/0 on 2026-07-03 — intermittent, race-shaped. The blamed test is
sequential; the racy neighbor `testConcurrentLocationUpdates_DoNotCrash`
mutates the shared mock from 100 `DispatchQueue.global()` closures.

## Root cause

`TPPBookRegistryMock` is `@unchecked Sendable` with unsynchronized mutable
state (its own doc comment forbade concurrent use). The concurrency test
violates that: `registry[id]?.location = location` from 100 threads races
ARC retain/release on the class-typed record's property → heap corruption →
deferred segv landing in the next test of the class. Production
`TPPBookRegistry` (split-lock Sendable, ba4a03c69) and
`TPPLastReadPositionSynchronizer` are NOT implicated — the synchronizer's
`@unchecked Sendable` justification requires exactly the thread-safety the
mock lacked.

## Claims

- makes `TPPBookRegistryMock` thread-safe: single `NSLock`, locked computed
  accessors for directly-accessed fields, private unlocked `_`-helpers for
  cross-method work (`preloadData` → `_addGenericBookmark`), Combine sends +
  NotificationCenter posts outside the lock
- rewrites `testMultipleSynchronizersWithSameRegistry_DoNotConflict` to drive
  two real `sync(for:book:drmDeviceID:)` calls concurrently via
  `withTaskGroup` (was: sequential `XCTAssertNotNil` fluff)
- single-sources the five shared bookmark wire keys: the private extension in
  `TPPBookLocation+Locator.swift` derives from
  `TPPBookmarkDictionaryRepresentation` (four keys widened from
  `fileprivate`); `toJSONDictionary()` literals replaced with the constants
- adds wire-format pin tests (`testWireFormatKeys_ArePinned`,
  `testToJSONDictionary_UsesPinnedWireKeys`) in `TPPReadiumBookmarkTests`
- adds detector `scripts/check-unsynchronized-sendable-mock.py` (+ pytest,
  6 cases) wired into `verify-pr.sh` and
  `scripts/pre-commit-phase35-detectors.sh` as blocking scan-mode; hook
  fixture test extended to assert fire + clean-pass (Assert 6)
- adds wall-failure entry `.forgeos/wall-failures/2026-07-05-sync-mock-race.md`
  + INDEX row
- annotates `TPPUserAccountMock` with the scope-deferral marker (18
  unsynchronized vars, wide blast radius — follow-up pass)

## Anti-claims

- does NOT change production `TPPBookRegistry`, `TPPBookRegistryRecord`, or
  `TPPLastReadPositionSynchronizer` logic
- does NOT change the persisted wire-format key VALUES (pinned by the new
  tests — that is the point)
- does NOT unify `TPPBookmarkSpec.locatorChapterProgressionKey` /
  `TPPBookmarkFactory` / `RecentlyReadingService` read-side literals
  (deferred; guarded by the pin test)
- does NOT lock `TPPUserAccountMock` (deferred with marker) or the three
  latent mocks (no concurrent usage today; detector notes them)

## Files in scope

- PalaceTests/Mocks/TPPBookRegistryMock.swift
- PalaceTests/Mocks/TPPUserAccountMock.swift (deferral marker comment only)
- PalaceTests/Reader2/TPPLastReadPositionSynchronizerTests.swift
- PalaceTests/Reader2/TPPReadiumBookmarkTests.swift
- Palace/Reader2/Bookmarks/TPPReadiumBookmark.swift
- Palace/Reader2/Bookmarks/TPPBookLocation+Locator.swift
- scripts/check-unsynchronized-sendable-mock.py (NEW)
- scripts/tests/test_check_unsynchronized_sendable_mock.py (NEW)
- scripts/tests/test_pre_commit_phase35_detectors.sh
- scripts/pre-commit-phase35-detectors.sh
- scripts/verify-pr.sh
- .forgeos/wall-failures/2026-07-05-sync-mock-race.md (NEW) + INDEX.md
- .forgeos/changesets/fix-sync-mock-race-segv-bookmark-keys/ (contract + review)
- .forgeos/intent/segv-class-mock-race-bookmark-keys.md (NEW)

## Verification

- Scoped: concurrency class + writer-delegation + bookmark + both position
  contract classes green; concurrency+bookmark classes soaked
  `-test-iterations 20` → `** TEST SUCCEEDED **`, no restart lines
- SSOT greps: each shared key string appears exactly once across the two files
- Detector pytest 6/6; hook fixture test 6/6 assertions incl. clean-diff pass
- Mutation `--diff-only` on both production files (result in commit body)
- `scripts/verify-pr.sh --quick` full battery (result in commit body)
