# Module C — Reader2 + PDF migration to PositionWriter

**Status:** skeleton — architect to refine on triage.

## In-scope files (exclusive write)

- MOD `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` (delegate save to PositionWriter; preserve `TPPBaseReaderViewController` call sites' API surface)
- MOD `Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift` (delegate load to PositionWriter; preserve conflict-merge semantics)
- MOD `PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift` (adapt to delegated path — verify the wiring + the EPUB-locator serialization layer)
- MOD `PalaceTests/Reader2/TPPLastReadPositionSynchronizerTests.swift` (adapt to delegated path)
- MOD `Palace/Reader2/UI/TPPBaseReaderViewController.swift` — ONE-LINE constructor edit if `TPPLastReadPositionPoster` initializer changes shape (read the file BEFORE deciding; preserve `lastReadPositionPoster` property name and call sites at lines 118, 353, 618)

## PDF position-write migration

Audit: `git grep -l "lastReadPosition" Palace/Reader3 Palace/Reader/ Palace/Reader2 PalacePDF*` to find the PDF position-write surface. If PDF currently uses a separate path (e.g. straight-to-network), migrate it through PositionWriter ONLY IF the migration is ≤30 LOC and doesn't widen this module's scope. Otherwise flag for a follow-up PR.

## Out-of-scope (read-only)

- `Palace/Audiobooks/*` (Module B's territory)
- All files in swarm-wide don't-touch list

## Behavior carve-out

`TPPLastReadPositionPoster`'s current responsibilities:
1. **Throttle save** (15s window via `lastReadPositionUploadDate`) — DELEGATES to PositionWriter.save
2. **EPUB locator serialization** (Readium locator → JSON) — STAYS LOCAL (it's format-specific; serializes into `PositionSnapshot.payload` as `.epubLocator`)
3. **Background-task scheduling** — DELEGATES (PositionWriter owns it)

`TPPLastReadPositionSynchronizer`:
1. **Load + conflict merge** (compare local vs remote, prefer newer) — DELEGATES the LOAD to PositionWriter; merge stays local

## Public surface (architect to lock — call sites in TPPBaseReaderViewController must compile unchanged)

```swift
final class TPPLastReadPositionPoster {
    init(book: TPPBook, positionWriter: PositionWriter, /* existing deps */)
    func storeReadPosition(locator: Locator)  // unchanged signature — callers at TPPBaseReaderViewController:353, 618
}

final class TPPLastReadPositionSynchronizer {
    init(positionWriter: PositionWriter, /* existing deps */)
    func sync(book: TPPBook) async -> Locator?  // returns the canonical position after merge
}
```

## Tests owned (architect to enumerate)

- `testStoreReadPosition_serializesLocator_delegatesToWriter`
- `testStoreReadPosition_throttle_doesNotPostAgain` — adapter doesn't override writer semantics
- `testStoreReadPosition_writerError_doesNotCrash`
- `testSync_remoteNewer_returnsRemote`
- `testSync_localNewer_returnsLocal`
- `testSync_remoteNil_returnsLocalOnly`
- `testSync_writerError_returnsLocalFallback`

## Acceptance criteria

- `TPPBaseReaderViewController.swift` recompiles without changes to call sites at lines 49, 118, 353, 618
- `TPPLastReadPositionPosterTests` + `TPPLastReadPositionSynchronizerTests` pass
- `PositionSyncTests.swift` + `ReadingPositionTests.swift` + `PositionSyncServiceTests.swift` (NOT owned by this module — read-only regression gates) continue to pass
- No new `Date()` arithmetic for throttling — that lives in PositionWriter now
- Net LOC reduction on the 2 modified Reader2 files (target: -30 LOC across both, since throttle + background scheduling code disappears)

## Implementer prompt

You are Module C implementer for `swarm_f4fbef9c`. You depend on Module A's `PositionWriter` protocol — read it BEFORE starting.

The `TPPBaseReaderViewController.swift` constructor at line 118 instantiates the poster. Change ONE LINE if needed to add the `positionWriter:` parameter. DO NOT change anything else in that file.

EPUB locator serialization stays in the Reader2 layer — `PositionSnapshot.payload` carries the serialized form. Match what the existing poster sends to the server.

PDF audit: if PDF uses a separate position-write surface, decide on triage whether to include it in this swarm or punt. Architect determines.

Validate: full build succeeds; `test -only-testing:PalaceTests/TPPLastReadPositionPosterTests` passes; `test -only-testing:PalaceTests/TPPLastReadPositionSynchronizerTests` passes; PositionSyncTests + PositionSyncServiceTests + ReadingPositionTests are NOT owned by this module but MUST continue to pass.

Write `.forgeos/swarms/swarm_f4fbef9c/transcripts/C-Reader2Migration.md` with: files modified, LOC delta, test count, EPUB-locator serialization decisions, PDF status (in/punted), TPPBaseReaderViewController edit (none/one-line). Skeleton FIRST.

Do NOT commit. Do NOT push. Stage for the integrator.
