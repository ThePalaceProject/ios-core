---
name: swarm_f3b9b087-contract-Audiobook-Position
type: immutable
status: active
created: 2026-05-21T03:25:00Z
last_refresh: 2026-05-21
freshness_window: never
owners: [audiobook]
description: "Contract: Audiobook-Position"
---

# Contract: Audiobook-Position

**Bucket items:** P0 #4, #5, P3 #10 (audiobook position state machine + TOC normalization)
**Priority:** P0 — audiobook position is a critical path (CLAUDE.md). Mutation-killing tests are MANDATORY.
**LOC estimate:** ~400–500 LOC (production + tests)

## Scope summary

Three defects in the audiobook position pipeline:

1. **`AudiobookBookmarkBusinessLogic.isAtBeginning` magic threshold (line ~85)** — `(sentTrackIndex == 0 && sentPlaybackTime < 30.0)` is a heuristic that suppresses "beginning" overwrites. The 30s constant is undocumented, unparameterized, and untested at the boundary. Patrons who genuinely pause in the first 30s of track 0 may have their position discarded if any newer track-0 position arrives. Need: extract the threshold to a documented named constant, document the trade-off, add boundary tests, and consider whether the timestamp-newer check (line 76–82) should always win (it currently does — good).
2. **`AudiobookSessionManager.getValidLocalPosition` (line 723–735) silently returns `nil` on bad data** — any failure in the optional-chain (missing location, can't decode bookmark, can't construct `TrackPosition`, position fails validation) is collapsed to `nil` with no log, no metric, no fallback to remote-only. Patron sees "starts from beginning" with zero diagnostic signal. Need: split the failure modes, log each with the existing `Log.warn(#file, ...)` pattern, and emit a single `[AUDIOPOS]` grep marker (mirror `[FCM_REG]` from `NotificationService.swift`).
3. **`AudiobookSessionManager.handlePositionUpdate` (line 1029, chapter TOC normalization)** — chapter-changed detection uses `position.track.key` equality AND `title` equality. If the TOC has two chapters with the same title (anthologies, "Untitled Track"), the equality check can fire a spurious chapter-change. Need: track-key equality alone should be the primary, with title as a tiebreaker only when track keys actually differ.

## Files in scope

- `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` (the audiobook-business-logic file living under Reader2/Bookmarks — confirmed verified path)
- `Palace/Audiobooks/AudiobookSessionManager.swift` (lines ~723–745 + ~1029–1044)
- `PalaceTests/AudiobookBookmarkBusinessLogicTests.swift` (extend)
- `PalaceTests/Audiobook/AudiobookSessionManagerTests.swift` (extend)
- `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift` (may extend if state contract is touched)

## Files OFF-LIMITS

- `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` — owned by **Reader2-ReadState**.
- `Palace/Reader2/Bookmarks/TPPReadiumBookmark.swift` — owned by **Reader2-ReadState**.
- `Palace/Reader2/UI/TPPBaseReaderViewController.swift` — owned by **Reader2-ReadState**.
- `Palace/Notifications/NotificationService.swift` — owned by **Notifications-FCM**.
- Anything in `Palace/MyBooks/`, `Palace/OPDS2/`, `Palace/ErrorHandling/`.

## Public type / protocol / signature changes

- **No public-surface changes expected.** All three fixes are internal to existing classes.
- If you extract `isAtBeginning` threshold to a `static let` on `AudiobookBookmarkBusinessLogic`, that's fine; do not make it part of an init signature unless a test demonstrably requires it. Default-parameter pattern from `feedback_test_patterns_phase7` is acceptable.
- If you introduce a `enum LocalPositionLoadFailure` to make `getValidLocalPosition` return `Result<TrackPosition, LocalPositionLoadFailure>`, that's a SCOPE EXPANSION — check with integrator first. Simpler: keep `TrackPosition?` return, add internal logging only.

## DI seam updates

- `AudiobookBookmarkBusinessLogic` already has `registry`, `book`, etc. injected — no new seams.
- `AudiobookSessionManager` is heavy; do NOT refactor its DI graph in this bucket. Add inline logging only.
- New tests should use existing `TPPBookMocker` for `TPPBook` factories (per CLAUDE.md "Key Patterns").

## Test contracts (CRITICAL PATH — mutation-killing MANDATORY)

### `AudiobookBookmarkBusinessLogicTests` (extend; mutation-killing **required**)

Add boundary + behavior tests for `isAtBeginning`:
- `testIsAtBeginning_track0_29s_isBeginning` — boundary, classifies as beginning.
- `testIsAtBeginning_track0_30s_isNotBeginning` — boundary exclusion.
- `testIsAtBeginning_track1_anyTime_isNotBeginning` — track-index gate.
- `testIsAtBeginning_track0_0s_isBeginning` — degenerate-low boundary.
- `testTimestampRaceWins_overBeginningPreventsOverride` — pin the existing line 76–82 timestamp-wins behavior (regression guard). Spy on `registry.setLocation` calls.
- Test must use a spy `BookRegistryProvider` recording call order — never `.shared`.

Mutation surface:
```
python3 scripts/palace_mutate.py \
  --file Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift \
  --tests PalaceTests/AudiobookBookmarkBusinessLogicTests
```
Required kill rate: **≥75%** on the diff (critical path; CLAUDE.md says "must kill at least one mutant" for critical paths — this bucket holds itself to a higher bar).

### `AudiobookSessionManagerTests` (extend; mutation-killing **required**)

Add tests for `getValidLocalPosition`:
- `testGetValidLocalPosition_noLocation_returnsNilAndLogs` — `bookRegistry.location(...)` returns nil → returns nil + emits `[AUDIOPOS] FAIL: no_location`.
- `testGetValidLocalPosition_corruptLocator_returnsNilAndLogs` — locationStringDictionary returns bad data → returns nil + emits `[AUDIOPOS] FAIL: locator_decode`.
- `testGetValidLocalPosition_positionExceeds110PercentDuration_returnsNil` — boundary on the `positionDuration > totalDuration * 1.1` check (line 743).
- `testGetValidLocalPosition_positionExactlyAtDuration_returnsValid` — boundary inclusion.
- `testGetValidLocalPosition_negativeTimestamp_returnsNil` — line 738 guard.
- `testGetValidLocalPosition_infiniteTimestamp_returnsNil` — line 738 `.isFinite` guard.

For TOC chapter-change normalization:
- `testHandlePositionUpdate_sameTrackDifferentTitle_doesNotFireChapterChange` — guards against the spurious-fire bug.
- `testHandlePositionUpdate_differentTrack_firesChapterChange` — regression guard.
- `testHandlePositionUpdate_sameTrackSameChapter_doesNotFire` — regression guard.
- Use a `chapterUpdatePublisher` sink (Combine) to record emissions; assert count + payload. Never use `sleep`.

### Contract snapshot (recommended for #4 + #5)

Consider adding `AudiobookPositionContractTests` under `PalaceTests/Contract/` recording the call order: `loadLocalBookmark → validate → handlePositionUpdate → updateNowPlaying`. Mirrors `BorrowOperationContractTests` pattern. This is OPTIONAL but high-value for an area with this many state transitions.

## Acceptance criteria

- `scripts/verify-pr.sh --quick` passes.
- Mutation kill rate **≥75%** on diff-scoped runs for both files (critical path).
- All chapter-change tests assert via Combine sinks with `XCTestExpectation` — no `sleep`.
- All tests use spy/mocks for `bookRegistry`, `manager`, `nowPlayingCoordinator`. NO `.shared`. NO `Keychain`. NO real network.
- Logging changes use existing `Log.{info,warn,error}` API + `[AUDIOPOS]` grep marker convention (mirrors `[FCM_REG]`).
- No public API changes. If you need them, STOP and consult integrator.
- New file(s) added to BOTH targets via `ruby scripts/pbxproj_add_swift.rb`.
- Commit message has `**Scope:**` and `**Not done:**` stanzas.
- Be aware: this code interacts with PalaceAudiobookToolkit (git submodule). Do NOT modify the submodule. If a test exposes a submodule bug, document it and defer.
- DO NOT commit. DO NOT push.
