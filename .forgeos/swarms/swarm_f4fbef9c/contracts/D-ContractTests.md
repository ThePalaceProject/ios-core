# Module D — Contract-snapshot tests

**Status:** refined by architect 2026-05-21. Scenario count locked at 13.

## In-scope files (exclusive write)

- NEW `PalaceTests/Contract/PositionWriterContractTests.swift` — 6 scenarios (canonical writer call order)
- NEW `PalaceTests/Contract/AudiobookPositionAdapterContractTests.swift` — 3 scenarios (Module B's wiring)
- NEW `PalaceTests/Contract/Reader2PositionAdapterContractTests.swift` — 4 scenarios (Module C's wiring including PDF)
- NEW snapshots under `PalaceTests/Contract/__Snapshots__/<TestClass>/<scenario>.json`

Total: **13 named scenarios** across 3 files.

## Out-of-scope (read-only)

- All production code (Modules A/B/C territory)
- `PalaceTests/Contract/CallLog.swift` + `ContractSnapshot.swift` (existing framework — read-only)
- All files in swarm-wide don't-touch list

## What's locked

This module owns the **call-order contract** for the canonical writer and its three adapters (audiobook + Reader2 EPUB + PDF). Locking the call order via `CallLog` + `ContractSnapshot` means a refactor that silently reorders dependency calls fails this test loudly.

Pattern matches existing `BorrowReducerContractTests.swift` and `BorrowOperationContractTests.swift` snapshots at `PalaceTests/Contract/__Snapshots__/BorrowReducerContractTests/`.

## Scenarios owned (13 LOCKED)

### `PositionWriterContractTests` — the canonical writer (6 scenarios)
1. `testCanonical_saveFirstSnapshot_postsImmediately` — expected: `network.post(snapshot)` exactly once, returns ServerPositionID; no other calls
2. `testCanonical_saveWithinThrottle_queuesOnly_noNetwork` — expected: zero `network.post` calls; queued internally
3. `testCanonical_saveTwiceWithinThrottle_overwritesQueue` — expected: zero `network.post` calls; only the latest queued (sequence: first save returns serverID, second save returns nil; advance clock + flush → network.post fires with the SECOND snapshot only)
4. `testCanonical_throttleElapsed_postsQueuedSnapshot` — expected: `clock advances → next save triggers network.post with the queued payload`
5. `testCanonical_loadDelegatesToAdapter` — expected: `network.fetch(bookID)` exactly once
6. `testCanonical_cancel_clearsPendingQueue` — expected: `save → save → cancel → advance clock → no network.post fires`

### `AudiobookPositionAdapterContractTests` — Module B's wiring (3 scenarios)
1. `testAudiobookBookmarkBusinessLogic_saveListeningPosition_callOrder` — expected sequence: `registry.setLocation → writer.save → (on success) registry.setLocation` (the second setLocation commits the server-assigned annotationId)
2. `testAudiobookBookmarkBusinessLogic_isAtBeginningGuard_preventsOverwrite` — expected: when current local position is in a later track and incoming save is at trackIndex=0 with playbackTime<30, NO `registry.setLocation` second-call fires (only the initial local commit); writer.save still fires but the response is ignored. This pins the swarm_f3b9b087 P0 fix.
3. `testAudiobookBookmarkBusinessLogic_timestampNewerRace_keepsLocal` — expected: when local timestamp is newer than the in-flight save's sent timestamp, the post-save commit is skipped. Pins swarm_f3b9b087's race-check predicate.

### `Reader2PositionAdapterContractTests` — Module C's wiring (4 scenarios)
1. `testTPPLastReadPositionPoster_storeReadPosition_callOrder` — expected: `shouldStore predicate passes → bookRegistry.setLocation → writer.save`
2. `testTPPLastReadPositionPoster_shouldStoreFalse_skipsCalls` — expected: zero calls to `bookRegistry.setLocation`, zero calls to `writer.save` (validates the EPUB-specific `shouldStore` predicate stays in place)
3. `testTPPLastReadPositionSynchronizer_sync_remoteFromDifferentDevice_returnsRemote` — expected: `writer.load → conflict-check (different device) → return server locator`
4. `testTPPPDFDocumentMetadata_save_canSyncTrue_callsWriter` — expected: `bookRegistry.setLocation → writer.save`. PDF path adapter coverage.

## Snapshot directory structure (LOCKED)

```
PalaceTests/Contract/__Snapshots__/
├── PositionWriterContractTests/
│   ├── canonical_saveFirstSnapshot_postsImmediately.json
│   ├── canonical_saveWithinThrottle_queuesOnly_noNetwork.json
│   ├── canonical_saveTwiceWithinThrottle_overwritesQueue.json
│   ├── canonical_throttleElapsed_postsQueuedSnapshot.json
│   ├── canonical_loadDelegatesToAdapter.json
│   └── canonical_cancel_clearsPendingQueue.json
├── AudiobookPositionAdapterContractTests/
│   ├── audiobookBookmarkBusinessLogic_saveListeningPosition_callOrder.json
│   ├── audiobookBookmarkBusinessLogic_isAtBeginningGuard_preventsOverwrite.json
│   └── audiobookBookmarkBusinessLogic_timestampNewerRace_keepsLocal.json
└── Reader2PositionAdapterContractTests/
    ├── tppLastReadPositionPoster_storeReadPosition_callOrder.json
    ├── tppLastReadPositionPoster_shouldStoreFalse_skipsCalls.json
    ├── tppLastReadPositionSynchronizer_sync_remoteFromDifferentDevice_returnsRemote.json
    └── tppPDFDocumentMetadata_save_canSyncTrue_callsWriter.json
```

Matches the pattern at `PalaceTests/Contract/__Snapshots__/BorrowReducerContractTests/`.

## Acceptance criteria

- First run of each test records a baseline at `__Snapshots__/<TestClass>/<scenario>.json` and fails with "snapshot recorded — re-run to verify".
- Second run asserts equality — must be green.
- 13 named scenarios across the 3 contract test files (6 + 3 + 4).
- `CONTRACT_SNAPSHOT_RECORD=1` documented in each file header.
- Each scenario JSON has 2+ recorded calls (otherwise the snapshot tells you nothing — promote to unit test instead).
- Scenarios 2 and 3 of `AudiobookPositionAdapterContractTests` (isAtBeginning + timestampNewer) explicitly cover the swarm_f3b9b087 P0 fix predicates — these MUST kill mutations on those predicate lines.

## Implementer prompt

You are Module D implementer for `swarm_f4fbef9c`. You depend on Modules A, B, C — the production code must compile and the spies must be writable against the real protocol.

**Step order:**
1. Write `transcripts/D-ContractTests.md` skeleton FIRST.
2. Read `PalaceTests/Contract/CallLog.swift` + `ContractSnapshot.swift` to understand the framework. Read `PalaceTests/Contract/BorrowReducerContractTests.swift` as a working pattern example.
3. Write `PositionWriterContractTests.swift` first (depends only on Module A). 6 scenarios using a spy `PositionNetworkAdapter` that records into a `CallLog`. Verify call order using `ContractSnapshot.assert(log, named: "scenarioName")`.
4. Write `AudiobookPositionAdapterContractTests.swift` (depends on Module B). 3 scenarios using a real `AudiobookBookmarkBusinessLogic` with a spy `PositionWriter` and spy `bookRegistry`.
5. Write `Reader2PositionAdapterContractTests.swift` (depends on Module C). 4 scenarios across `TPPLastReadPositionPoster`, `TPPLastReadPositionSynchronizer`, and `TPPPDFDocumentMetadata`.
6. First run records baselines — review them in `git diff PalaceTests/Contract/__Snapshots__/` BEFORE committing. Watch for over-recording (a snapshot with 30 recorded calls usually means the spy is too granular; promote to a unit test).
7. Fill the transcript with test files added, scenario count (13), snapshots locked, key call-order observations (a specific regression each snapshot catches — e.g., "if someone reorders `bookRegistry.setLocation` and `writer.save` in `AudiobookBookmarkBusinessLogic`, scenario 1 fails because the recorded call order changes").

Use the existing `CallLog.swift` + `ContractSnapshot.swift` framework. Pattern matches `BorrowReducerContractTests.swift`.

Each scenario JSON must record 2+ calls. If you find yourself recording only one call, the scenario is too narrow — either expand it or replace with a direct XCTAssertEqual unit test.

Validate: `test -only-testing:PalaceTests/PositionWriterContractTests` records all 6 baselines on first run, then is green on re-run; same for the two adapter contract test classes (3+4=7 more baselines).

Do NOT commit. Do NOT push. Stage for the integrator.
