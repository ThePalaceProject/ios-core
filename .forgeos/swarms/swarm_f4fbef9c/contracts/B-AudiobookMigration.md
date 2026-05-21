# Module B — Audiobook-side migration to PositionWriter

**Status:** skeleton — architect to refine on triage.

## In-scope files (exclusive write)

- MOD `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` (345 LOC currently — delete network sync; delegate to PositionWriter)
- MOD `Palace/Audiobooks/Tracker/AudiobookTimeTracker.swift` (213 LOC currently — keep play-time tracking; migrate position-write side only)
- DELETE `Palace/Audiobooks/LatestAudiobookLocation.swift` (19 LOC — fold model into PositionSnapshot)
- MOD `PalaceTests/Audiobook/AudiobookDataManagerSyncTests.swift` (adapt to delegated path — syncQueue may still exist locally for play-time stats; position-write path moves to PositionWriter)
- MOD `PalaceTests/Audiobooks/AudiobookEventsTests.swift` (4 sites use `dataManager.syncQueue.sync {}` — architect to determine if syncQueue stays for play-time stats or test pattern changes)

## Out-of-scope (read-only)

- `Palace/Audiobooks/AudiobookSessionManager.swift` (READ-ONLY — verify the `AudiobookBookmarkDelegate` adapter still satisfies the toolkit-side protocol. If a one-line edit is needed to wire the new PositionWriter, FLAG to integrator; otherwise leave alone)
- `Palace/Audiobooks/AudiobookPositionPolicy.swift` (read-side restoration; not on write path)
- `Palace/Audiobooks/Tracker/AudiobookTimeEntry.swift` (data model only)
- `Palace/Audiobooks/Tracker/DataManager.swift` (legacy adapter — leave alone)
- All files in swarm-wide don't-touch list

## Behavior carve-out

`AudiobookDataManager`'s current responsibilities:
1. **Time tracking** (play-time entries; `AudiobookTimeTracker` writes here) — STAYS LOCAL TO MODULE
2. **Position network sync** (POST to /tracking endpoint with bookID + position + device) — MOVES to PositionWriter via injection
3. **Background-task scheduling** (UIApplication background tasks) — MOVES to PositionWriter as part of the network sync delegation

The carve-out is: time tracking continues to live in `AudiobookDataManager`. Position write becomes a single delegation call to the injected `PositionWriter`.

## Public surface

```swift
final class AudiobookDataManager {
    init(positionWriter: PositionWriter, /* existing time-tracking deps */)
    // Existing time-tracking API unchanged
    func recordPlayTime(...) { /* unchanged */ }
    // Position-write API becomes a thin pass-through
    func savePosition(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? {
        try await positionWriter.save(snapshot)
    }
}
```

## Tests owned (architect to enumerate)

- `testSavePosition_delegatesToPositionWriter` — record-and-verify against a spy PositionWriter
- `testSavePosition_throttled_returnsNil` — adapter doesn't override writer semantics
- `testSavePosition_networkError_propagates` — error pass-through
- `testRecordPlayTime_unchanged_writesToSyncQueue` — regression for the unaffected path
- `testSyncQueue_stillAccessibleForTests` — if architect keeps syncQueue for play-time

## Acceptance criteria

- `Palace/Audiobooks/LatestAudiobookLocation.swift` deleted
- `git grep "LatestAudiobookLocation" Palace --include="*.swift"` returns 0 (or only the deletion commit)
- `AudiobookDataManager.swift` net LOC ↓ (target: -50 LOC from removing network sync)
- All existing `AudiobookDataManagerSyncTests` cases still pass (adapted to delegated path)
- All existing `AudiobookEventsTests` cases still pass

## Implementer prompt

You are Module B implementer for `swarm_f4fbef9c`. You depend on Module A's `PositionWriter` protocol — read `Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/PositionWriter.swift` BEFORE starting.

The play-time tracking responsibility stays in `AudiobookDataManager`. Only the position-write code path moves out.

`LatestAudiobookLocation.swift` (19 LOC) is a data model — its fields fold into `PositionSnapshot.payload` for `.audiobook` format. Audit call sites BEFORE deleting.

`AudiobookSessionManager.swift` is READ-ONLY — verify the `AudiobookBookmarkDelegate` conformance still works. If you need to change one line there to wire the new writer, FLAG to integrator in the transcript and DO NOT change it yourself. Swarm 3 owns that file.

Validate: `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds; `test -only-testing:PalaceTests/AudiobookDataManagerSyncTests` passes; `test -only-testing:PalaceTests/AudiobookEventsTests` passes.

Write `.forgeos/swarms/swarm_f4fbef9c/transcripts/B-AudiobookMigration.md` with: files modified, files deleted, LOC delta on AudiobookDataManager, test count, key decisions, any gaps (especially the AudiobookSessionManager delegate question).

Write the transcript skeleton FIRST. Swarm 1 lesson.

Do NOT commit. Do NOT push. Stage for the integrator.
