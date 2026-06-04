---
name: swarm_f4fbef9c-contract-B-AudiobookMigration
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [audiobook]
description: Module B — Audiobook position-write migration
---

# Module B — Audiobook position-write migration

**Status:** refined by architect 2026-05-21. **Major scope correction** — see `transcripts/triage.md` Deviations 1, 2, 3.

## Scope correction summary

The original contract target (`AudiobookDataManager.swift`) is **not** a position writer; it's a time-tracker for play-time analytics. The actual audiobook position-write surface lives in `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift:37-110` (`saveListeningPosition` + `syncListeningPositionToServer`). Module B's revised target is `AudiobookBookmarkBusinessLogic`.

Despite the name, that file is on the audiobook write path — it implements `AudiobookBookmarkDelegate` (toolkit protocol from `ios-audiobooktoolkit/PalaceAudiobookToolkit/Core/AudiobookManager.swift:31`) and is wired in at `Palace/Audiobooks/AudiobookLoader.swift:531` (Swarm 1 territory — read-only for this swarm).

## In-scope files (exclusive write)

- MOD `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` (535 LOC currently — replace `debounce { syncListeningPositionToServer(...) }` block at lines 47-51 with `Task { try? await positionWriter.save(snapshot) }`; preserve conflict-resolution logic at lines 76-96)
- DELETE `Palace/Audiobooks/LatestAudiobookLocation.swift` (19 LOC, dead — see Deviation 3)
- MOD `PalaceTests/Audiobook/AudiobookTimeEntryTests.swift` — delete the `LatestAudiobookLocationTests` class block at lines 94-141 (its 3 tests are fluff against dead global; comment at top of file at line 5 also drops the LatestAudiobookLocation reference)
- (Optional) NEW `PalaceTests/Audiobook/AudiobookBookmarkBusinessLogicPositionWriteTests.swift` — adapter tests for the migrated save path (architect recommends but does not require; Module D's contract tests will cover this from a different angle)

## Don't-touch (corrected from original)

- `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` — **NOT a position writer.** Time-tracking only. Leave alone.
- `Palace/Audiobooks/Tracker/AudiobookTimeTracker.swift` — same.
- `Palace/Audiobooks/Tracker/AudiobookTimeEntry.swift` — data model for time entries.
- `PalaceTests/Audiobook/AudiobookDataManagerSyncTests.swift` — verifies time-tracker behavior; NOT in scope.
- `PalaceTests/Audiobooks/AudiobookEventsTests.swift` — the syncQueue these tests `sync {}` on is `AudiobookDataManager.syncQueue` (the time-tracker's); NOT in scope.
- `Palace/Audiobooks/AudiobookSessionManager.swift` — does NOT reference `AudiobookBookmarkDelegate`. No edit needed.
- `Palace/Audiobooks/AudiobookLoader.swift` — Swarm 1 territory. The delegate wire-up at line 531 stays. See "Default writer construction" below.
- All files in swarm-wide don't-touch list.

## Behavior carve-out for `AudiobookBookmarkBusinessLogic`

Current responsibilities (after swarm_f3b9b087 commit 520573305 hardened the predicates):

1. **`saveListeningPosition(at:completion:)`** (lines 37-51)
   - Local save via `registry.setLocation(...)` — STAYS LOCAL TO MODULE
   - `debounce { syncListeningPositionToServer(...) }` — DELEGATES to `PositionWriter.save`
2. **`syncListeningPositionToServer(at:completion:)`** (lines 53-110)
   - Conflict-resolution (timestamp-newer + isAtBeginning) — STAYS LOCAL (audiobook-specific)
   - `annotationsManager.postListeningPosition(...)` (line 67) — REPLACED by `try? await positionWriter.save(snapshot)`
   - On success: `registry.setLocation(audioBookmark.toTPPBookLocation(), forIdentifier:)` — STAYS LOCAL (final commit of server-assigned ID)
3. **`saveBookmark(at:completion:)`** (lines 112-140) — UNRELATED (saves named bookmarks, not reading position). Untouched.
4. **`fetchBookmarks(...)`** (lines 142+) — UNRELATED. Untouched.

## Default writer construction (avoids editing AudiobookLoader.swift)

The constructor of `AudiobookBookmarkBusinessLogic` is currently `init(book: TPPBook)` (call site `AudiobookLoader.swift:531`). Module B adds a defaulted parameter:

```swift
init(
    book: TPPBook,
    positionWriter: PositionWriter? = nil,
    annotationsManager: AudiobookAnnotationsManagerProtocol? = nil,
    /* existing deps with defaults */
) {
    self.positionWriter = positionWriter ?? AppContainer.production().positionWriter
    /* ... */
}
```

This keeps `AudiobookLoader.swift:531` (`AudiobookBookmarkBusinessLogic(book: book)`) compiling unchanged. The default falls back to the AppContainer's writer (Module A provides the wiring in AppContainer).

**Alternative:** if AppContainer access is not desirable in this module, Module B can construct a default `RemotePositionWriter` inline using `AppContainer.production().networkExecutor` as the adapter source. The integrator can clean this up in the AppContainer wiring follow-up if needed.

## Public surface

```swift
public class AudiobookBookmarkBusinessLogic: NSObject {
    init(
        book: TPPBook,
        positionWriter: PositionWriter? = nil,  // NEW — defaults preserve call-site compat
        annotationsManager: AudiobookAnnotationsManagerProtocol? = nil,
        // existing deps...
    )

    public func saveListeningPosition(at position: TrackPosition, completion: ((String?) -> Void)?)
    public func saveBookmark(at position: TrackPosition, completion: ((TrackPosition?) -> Void)?)
    public func deleteBookmark(at position: TrackPosition, completion: ((Bool) -> Void)?)
    public func fetchBookmarks(for: Tracks, toc: [Chapter], completion: @escaping ([TrackPosition]) -> Void)
}
```

## Behavior change to flag in QA notes

**Throttle window change:** the current `debounce { ... }` collapses rapid saves; the new `PositionWriter.save` uses a 15.0-second throttle window. Expected user-visible effect: at most one server POST per 15s of active playback. In rapid track-skip cycles the existing debounce already coalesces, so net impact is small. Document in transcript so QA can confirm via simdrive replay.

## Tests owned

- `testSaveListeningPosition_savesLocallyImmediately` — verify the `registry.setLocation` call fires before any async work. (regression against the swarm_f3b9b087 "save locally first" rule)
- `testSaveListeningPosition_delegatesNetworkSaveToPositionWriter` — record + verify against a spy `PositionWriter`
- `testSaveListeningPosition_writerThrottled_localStillCommitted` — local save unaffected by writer queueing
- `testSaveListeningPosition_writerError_doesNotCrash_completionCalledWithNil`
- `testIsAtBeginning_preservedAfterMigration_doesNotOverwriteValidPosition` — pin the swarm_f3b9b087 predicate (`trackIndex == 0 && playbackTime < 30.0` guard against overwrite when current local is in a later track)
- `testTimestampNewerRace_preservedAfterMigration_keepsLocal` — pin the swarm_f3b9b087 race-check predicate

The last 2 tests are critical-path mutation kills for the swarm_f3b9b087 P0 fix; Module B MUST NOT regress those predicates.

## Acceptance criteria

- `Palace/Audiobooks/LatestAudiobookLocation.swift` deleted (19 LOC removed).
- `LatestAudiobookLocationTests` class block (lines 94-141 of `PalaceTests/Audiobook/AudiobookTimeEntryTests.swift`) deleted.
- `git grep "LatestAudiobookLocation\|latestAudiobookLocation" Palace PalaceTests --include='*.swift'` returns 0 (or only the deletion commit).
- `AudiobookBookmarkBusinessLogic.swift` net LOC change: -10 to -20 (the `syncListeningPositionToServer` 57-line method shrinks to a ~30-line method calling `positionWriter.save`).
- `xcodebuild ... build` succeeds with `Palace/Audiobooks/AudiobookLoader.swift` unchanged.
- All existing audiobook-position tests pass: `AudiobookPositionPolicyTests`, plus any tests in `AudiobookBookmarkBusinessLogicTests` if they exist.
- 6 new/refactored tests for `AudiobookBookmarkBusinessLogic.saveListeningPosition` covering the local-save-first invariant and the swarm_f3b9b087 predicates.

## Implementer prompt

You are Module B implementer for `swarm_f4fbef9c`. **Read `transcripts/triage.md` FIRST** — the original contract pointed you at the wrong file. The real audiobook position-write surface is `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` (despite the directory name).

You depend on Module A's `PositionWriter` protocol — read `Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/PositionWriter.swift` BEFORE starting.

**Step order:**
1. Write `transcripts/B-AudiobookMigration.md` skeleton FIRST.
2. Read the current `AudiobookBookmarkBusinessLogic.swift` (especially lines 37-110) and the conflict-resolution logic (lines 76-96). Memorize the swarm_f3b9b087 predicates — they MUST survive.
3. Replace the `debounce { syncListeningPositionToServer(...) }` block (lines 47-51) with a `Task` that calls `positionWriter.save(snapshot)`. Inline-construct the `PositionSnapshot` from the `TrackPosition` + locator string. Format is `.audiobook`. Payload is the JSON-encoded `tppLocation.locationString` as `Data`.
4. Preserve the local-save-first ordering (lines 41-45): `registry.setLocation` BEFORE any async work. This is non-negotiable — the swarm_f3b9b087 fix relied on it.
5. Preserve the conflict-resolution logic that currently runs INSIDE `syncListeningPositionToServer`'s response handler (lines 76-96). Move it into a `Task` that awaits `positionWriter.save` then checks `registry.location(...)` for the latest local and applies the same race-check before committing the server-assigned `annotationId`.
6. Delete `Palace/Audiobooks/LatestAudiobookLocation.swift` (19 LOC, dead). Delete the `LatestAudiobookLocationTests` class block (lines 94-141 of `PalaceTests/Audiobook/AudiobookTimeEntryTests.swift`). Update the comment at line 5 of that file.
7. Write tests for the 6 named cases above. Use a spy `PositionWriter` that records `save` calls.
8. **DO NOT EDIT `Palace/Audiobooks/AudiobookLoader.swift`.** The `AudiobookBookmarkBusinessLogic(book: book)` call site at line 531 must continue to compile. Use defaulted parameters in the new init.
9. Run `xcodebuild ... build` to verify.
10. Run targeted tests: `-only-testing:PalaceTests/AudiobookBookmarkBusinessLogicTests` (if file exists; otherwise the new file you created).
11. Fill the transcript with files modified, files deleted, LOC delta, test count, key decisions, the throttle-window behavior-change note for QA, and confirmation that `AudiobookLoader.swift` was NOT touched.

**Don't touch:**
- `Palace/Audiobooks/Tracker/*` (time-tracking, not position-write)
- `Palace/Audiobooks/AudiobookSessionManager.swift`
- `Palace/Audiobooks/AudiobookLoader.swift`
- `PalaceTests/Audiobook/AudiobookDataManagerSyncTests.swift` (verifies time-tracker)
- `PalaceTests/Audiobooks/AudiobookEventsTests.swift` (verifies time-tracker)
- All files in swarm-wide don't-touch list.

Validate: `xcodebuild ... build` succeeds; `test -only-testing:PalaceTests/AudiobookBookmarkBusinessLogicTests` passes; `git grep LatestAudiobookLocation` returns 0.

Do NOT commit. Do NOT push. Stage for the integrator.
