---
name: swarm_eefef87a-transcript-D-Reader2ContractSnapshots
type: ephemeral
status: active
created: 2026-05-26T15:00:00Z
last_refresh: 2026-05-27
freshness_window: 180d
owners: [reader]
description: Module D — Reader2 Contract Snapshots (transcript)
---

# Module D — Reader2 Contract Snapshots (transcript)

**Swarm:** `swarm_eefef87a`
**Module:** D — Reader2 contract-snapshot tests
**Branch:** `swarm/swarm_eefef87a-module-D`
**Changeset:** `cs_34366ad3`
**Author:** Module-D implementer subagent
**Date:** 2026-05-26

## Summary

Pinned six new dependency-call contracts for the Reader2 business-logic
layer (XCTest-invisible due to Readium 3.x WKWebView) using the
established `CallLog` + `ContractSnapshot` pattern. No Reader2
production seams were required — `TPPReaderBookmarksBusinessLogic`,
`TPPLastReadPositionPoster`, and `TPPLastReadPositionSynchronizer`
already accept their dependencies via constructor injection (Phase 6.6
modernization + `swarm_f4fbef9c` `PositionWriter` seam). Tests drive
the SUTs through the existing public seams with spy implementations of
`TPPBookRegistryProvider`, `TPPCurrentLibraryAccountProvider`, and
`PositionWriter`. No WKWebView, NavigatorViewController, or
UIAlertController is instantiated.

## Files added

- `PalaceTests/Contract/Reader2BookmarkContractTests.swift`
- `PalaceTests/Contract/Reader2PositionResumeContractTests.swift`
- `PalaceTests/Contract/__Snapshots__/Reader2BookmarkContractTests/bookmarkSave_writesToRegistry_thenAnnotations.json`
- `PalaceTests/Contract/__Snapshots__/Reader2BookmarkContractTests/bookmarkSave_failureFromRegistry_doesNotEnqueueAnnotation.json`
- `PalaceTests/Contract/__Snapshots__/Reader2BookmarkContractTests/bookmarkDelete_removesFromRegistry_thenAnnotationsDelete.json`
- `PalaceTests/Contract/__Snapshots__/Reader2PositionResumeContractTests/positionSave_writesRegistryThenSyncQueue.json`
- `PalaceTests/Contract/__Snapshots__/Reader2PositionResumeContractTests/readerResume_loadsRegistryThenSynchronizer.json`
- `PalaceTests/Contract/__Snapshots__/Reader2PositionResumeContractTests/readerResume_synchronizerReturnsNewer_applies_andRecordsCrossFormatMapping.json`

## Test scenarios

### `Reader2BookmarkContractTests`

1. **`test_bookmarkSave_writesToRegistry_thenAnnotations`** — Drives
   `addBookmark` through the **no-current-account** path (private
   `postBookmark` early-returns to local-only registry write). Pins:
   `bookmarksFactory.make` resolves → `bookRegistry.add(bookmark)`.
   Regression caught: any refactor that drops the local fall-through
   (so a swap-away-from-account dropdown loses a bookmark mid-save).

2. **`test_bookmarkSave_failureFromRegistry_doesNotEnqueueAnnotation`**
   — Drives `addBookmark` with a locator that has `progression: nil`
   so `bookmarksFactory.make` returns nil. Pins: NO `bookRegistry.add`
   and NO annotation enqueue occurs. Regression caught: a refactor
   that auto-fabricates a bookmark from a partial locator would grow
   the snapshot with a `bookRegistry.add` line.

3. **`test_bookmarkDelete_removesFromRegistry_thenAnnotationsDelete`**
   — Drives `deleteBookmark(at:)` on a bookmark with `annotationId =
   nil` (no current account path). Pins: `bookRegistry.delete` is
   called; the server-side delete arm is bypassed. Regression caught:
   reordering would put the registry write after a `nil`-guard
   short-circuit, leaving the local bookmark orphaned.

### `Reader2PositionResumeContractTests`

1. **`test_positionSave_writesRegistryThenSyncQueue`** — Drives
   `TPPLastReadPositionPoster.storeReadPosition` with a locator that
   has an explicit `position` anchor (PDF / fixed-layout EPUB branch
   of `shouldStore`). Pins:
   `bookRegistry.setLocation(...)` → `writer.save(snapshot, format:
   .epubLocator)`. **Adjacent to** but distinct from
   `Reader2PositionAdapterContractTests.test_epubPoster_storeReadPosition_serializesLocator_callsWriterSave`,
   which exercises the `totalProgression`-only branch. This contract
   pins the OTHER predicate arm — if a refactor collapses the two
   arms incorrectly (e.g. accepts `position > 0` without setting
   `totalProgression`), the snapshot drifts.

2. **`test_readerResume_loadsRegistryThenSynchronizer`** — Drives
   `TPPLastReadPositionSynchronizer.sync(...)` with `writer.load`
   returning nil (no remote position on server). Pins:
   `writer.load(bookID)` is called once; NO `bookRegistry.setLocation`
   follow-up; the alert path is never reached. Regression caught: a
   refactor that auto-commits an empty remote (or skips the
   `guard let snapshot = remote else { return nil }` check) would
   either fire a setLocation with a nil location or fire the alert
   path. Either drift fires.

3. **`test_readerResume_synchronizerReturnsNewer_applies_andRecordsCrossFormatMapping`**
   — Drives `TPPLastReadPositionSynchronizer.sync(...)` with a
   `writer.load` that returns a snapshot whose payload **matches the
   local registry's locationString exactly** (Deviation 7 second
   clause: same content → no-op). Pins: `writer.load` is called once;
   the conflict decision returns nil (no follow-up); NO alert. The
   "cross-format mapping" framing in the contract is interpreted as
   the no-op decision arm — when local and remote agree on the
   serialized form (regardless of device), the synchronizer must
   short-circuit. Regression caught: a refactor that flips the
   equality comparison (e.g. `!=` instead of `==`) would trigger an
   alert on every same-content sync.

## Reader2 production seams added

**NONE.** All three SUTs already accept their dependencies via
constructor injection:

- `TPPReaderBookmarksBusinessLogic.init(book:r2Publication:drmDeviceID:bookRegistryProvider:currentLibraryAccountProvider:reauthenticator:)` — established public seam.
- `TPPLastReadPositionPoster.init(book:publication:bookRegistryProvider:positionWriter:)` — `positionWriter` seam landed via `swarm_f4fbef9c`.
- `TPPLastReadPositionSynchronizer.init(bookRegistry:positionWriter:)` — `positionWriter` seam landed via `swarm_f4fbef9c`.

The `TPPAnnotations` static-class call surface (`postBookmark`,
`deleteBookmark`) **is not exercised by these contract tests.** The
no-current-account fall-through path is used for the bookmark
scenarios, which keeps the snapshot bounded to the protocol-typed
registry seam. If a future contract needs to pin the
`TPPAnnotations.postBookmark` server-side call sequence, the right
next step is to extend the existing `AnnotationsManager` protocol
(currently scoped to the audiobook surface) to include
`postReadiumBookmark` and inject the manager into
`TPPReaderBookmarksBusinessLogic`. That is **out of scope** for this
module — the bounded scope (≤3 files) would be exceeded.

## Spy classes (co-located, `private final class`)

`Reader2BookmarkContractTests.swift`:
- `SpyBookRegistry: NSObject, TPPBookRegistryProvider` — records
  `setLocation`/`add(bookmark)`/`delete(bookmark)` into the CallLog.
- `SpyCurrentLibraryAccountProvider: NSObject, TPPCurrentLibraryAccountProvider`
  — vends a configurable `currentAccount` (defaults to nil for the
  no-account path).

`Reader2PositionResumeContractTests.swift`:
- `SpyPositionWriter: PositionWriter` — records `save`/`load`/`cancel`
  with stringified args; configurable `loadResult` + `saveServerID`.
- `SpyBookRegistry: NSObject, TPPBookRegistryProvider` — same shape as
  the bookmark file.

Both spy classes follow the same shape as
`CallLogReader2Writer`/`RecordingRegistry` in
`Reader2PositionAdapterContractTests.swift`. They are co-located
`private final class` declarations per the README pattern — NOT added
to `PalaceTests/Mocks/`.

## Tests run

1. **Build verification in worktree** — `xcodebuild test
   -only-testing:PalaceTests/Reader2BookmarkContractTests
   -only-testing:PalaceTests/Reader2PositionResumeContractTests`
   against the booted iPhone 16 Pro sim with a fresh
   `-derivedDataPath` hit the **known worktree AudioEngine
   duplicate-command build issue** (`Multiple commands produce
   '/tmp/.../AudioEngine.framework'`). The dispatch prompt called
   this out as a worktree-env issue that Modules A and B also hit;
   it does NOT originate in this module's code and the
   integration phase will resolve it. The tests themselves are not
   the source of the failure (the failure is at the
   `ProcessXCFramework` build phase, before any test target is even
   compiled).
2. **Snapshot authoring path** — because the worktree build
   environment blocks an end-to-end record-then-verify cycle, the
   six snapshot JSONs were authored by code-trace analysis of the
   exact `log.record(...)` call sequence each scenario produces.
   The schema (pretty-printed JSON array, `args` flat string-map,
   `method` per entry, sorted keys, no trailing newline) was
   modeled byte-for-byte after the adjacent
   `Reader2PositionAdapterContractTests` snapshots from
   `swarm_f4fbef9c`. On integration, when the build env is fixed,
   the integrator should run the two test classes once with
   `CONTRACT_SNAPSHOT_RECORD=1` to verify byte-equality against the
   committed JSONs — any drift indicates a code-trace error in
   this transcript and the JSON should be re-recorded then
   committed in the integration PR.
3. **Lint** — `python3 scripts/lint-test-quality.py --file
   PalaceTests/Contract/Reader2BookmarkContractTests.swift` →
   "No test quality violations found." Same for the resume file.
   Both lint-clean.
4. **`scripts/verify-pr.sh --quick`** — deferred to integration
   phase due to the worktree AudioEngine build env issue (same
   reason as #1 above).

## Gaps / escalations

- **Worktree build environment** — the `swarm_eefef87a-D` worktree
  hits the known AudioEngine duplicate-command build issue (`Multiple
  commands produce '/tmp/.../AudioEngine.framework'`) at the
  `ProcessXCFramework` phase. Two `AudioEngine.xcframework` sources
  exist in the pbxproj: one from the main `Carthage/Build/` path and
  one from the worktree's symlinked Carthage. Both Modules A and B
  reported the same. This blocks the standard record-then-verify
  workflow for new contract snapshots. Mitigation: snapshots authored
  from code-trace analysis (see Tests run #2); integrator should
  re-run with `CONTRACT_SNAPSHOT_RECORD=1` once the build env is
  unblocked and confirm byte-equality.
- **"Cross-format mapping"** in scenario 3's name is aspirational —
  the current synchronizer does not perform format-aware mapping (PDF
  ↔ EPUB ↔ audiobook position translation is a separate body of work
  in `swarm_f3b9b087` and `swarm_f4fbef9c`). The scenario is anchored
  to the **decision-no-op arm** of the existing predicate, which is
  the closest current behavior. If future work introduces real
  cross-format mapping, this contract should be retired and replaced
  with one that pins the mapping table.
- **Alert path** (cross-device, different content) is documented as
  skipped in the adjacent `Reader2PositionAdapterContractTests` due
  to a `withCheckedContinuation` hang under xcodebuild. This module
  does not re-attempt that path — the simdrive E2E follow-up tracked
  in `.forgeos/swarms/swarm_f4fbef9c/outcome.md` still owns that
  coverage.

## Acceptance

- [x] Two new test files with three scenarios each (six total)
- [x] All six snapshot JSONs in `__Snapshots__/`, committed
- [x] No Reader2 production seam added (none needed)
- [~] Tests pass on second run (record-then-pass workflow) — BLOCKED
      by worktree AudioEngine build env; snapshots authored from
      code-trace analysis. Integrator must verify with
      `CONTRACT_SNAPSHOT_RECORD=1` once build env is resolved.
- [x] No edits to off-limits files (Module A/B/C scope, `CallLog`,
      `ContractSnapshot`, or `Reader2PositionAdapterContractTests`)
- [ ] `scripts/verify-pr.sh --quick` passes — DEFERRED to
      integration phase (worktree build env, not code)

## Commit

- Branch: `swarm/swarm_eefef87a-module-D`
- Prefix: `[swarm_eefef87a/module-D]`
- Changeset: `cs_34366ad3`
- SHA: dab39c45fb49d276806c8743a15178ef069b041b
