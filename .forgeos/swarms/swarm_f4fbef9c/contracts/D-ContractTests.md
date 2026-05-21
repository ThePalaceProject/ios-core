# Module D — Contract-snapshot tests

**Status:** skeleton — architect to refine on triage.

## In-scope files (exclusive write)

- NEW `PalaceTests/Contract/PositionWriterContractTests.swift`
- NEW `PalaceTests/Contract/AudiobookPositionAdapterContractTests.swift`
- NEW `PalaceTests/Contract/Reader2PositionAdapterContractTests.swift`
- NEW snapshots under `PalaceTests/Contract/__Snapshots__/`

## Out-of-scope (read-only)

- All production code (Modules A/B/C territory)
- `PalaceTests/Contract/CallLog.swift` + `ContractSnapshot.swift` (existing framework — read-only)
- All files in swarm-wide don't-touch list

## What's locked

This module owns the **call-order contract** for the canonical writer and its two adapters (audiobook + Reader2). Locking the call order via `CallLog` + `ContractSnapshot` means a refactor that silently reorders dependency calls fails this test loudly.

## Scenarios owned (architect to enumerate)

### PositionWriterContractTests (the canonical writer)
1. `testCanonical_saveFirstSnapshot_postsThenCaches` — `network.post → cache.set`
2. `testCanonical_saveWithinThrottle_queuesOnly_noNetwork` — `cache.set` only, no `network.post`
3. `testCanonical_throttleElapsed_postsQueued` — `clock.tick → network.post → cache.set`
4. `testCanonical_load_cacheMiss_fetchesAndCaches` — `cache.get(nil) → network.fetch → cache.set → return`
5. `testCanonical_load_cacheHit_skipsNetwork` — `cache.get(snapshot) → return`
6. `testCanonical_cancel_clearsQueueAndCache` — `queue.clear → cache.invalidate(bookID)`

### AudiobookPositionAdapterContractTests (Module B's wiring)
1. `testAudiobookDataManager_savePosition_delegatesToWriter` — `writer.save` called once
2. `testAudiobookDataManager_recordPlayTime_doesNotTouchWriter` — only `syncQueue.async`, no `writer.save`

### Reader2PositionAdapterContractTests (Module C's wiring)
1. `testPoster_storeReadPosition_serializesLocator_callsWriterSave` — `locator → snapshot → writer.save`
2. `testSynchronizer_sync_remoteNewer_callsWriterLoadThenReturnsRemote` — `writer.load → merge → return remote`
3. `testSynchronizer_sync_localNewer_callsWriterLoadThenReturnsLocal` — `writer.load → merge → return local`

## Acceptance criteria

- First run of each test records a baseline at `__Snapshots__/<TestClass>/<scenario>.json` and fails with "snapshot recorded — re-run to verify"
- Second run asserts equality — must be green
- 11+ named scenarios across the 3 contract test files
- `CONTRACT_SNAPSHOT_RECORD=1` is documented in the file header as the re-record toggle (matches existing `BorrowReducerContractTests` pattern)
- Each scenario JSON has 3+ recorded calls (otherwise the snapshot tells you nothing — promote those to unit tests instead)

## Implementer prompt

You are Module D implementer for `swarm_f4fbef9c`. You depend on Modules A, B, C — the production code must compile and the spies must be writable against the real protocol.

Use the existing `CallLog.swift` + `ContractSnapshot.swift` framework — read those files first. Pattern matches existing `BorrowReducerContractTests.swift` and `BorrowOperationContractTests.swift`.

Each test instantiates the production class under test with spy dependencies. The spies record into a `CallLog`. After exercising the scenario, call `ContractSnapshot.assert(log, named: "scenarioName")`.

First run records baselines — commit them. Subsequent runs assert equality.

Validate: `test -only-testing:PalaceTests/PositionWriterContractTests` records all baselines on first run, then is green on re-run; same for the adapter contract tests; visible diff in `git diff PalaceTests/Contract/__Snapshots__/` BEFORE COMMITTING — review baselines for accidental over-recording.

Write `.forgeos/swarms/swarm_f4fbef9c/transcripts/D-ContractTests.md` with: test files added, scenario count, snapshots locked, key call-order observations from the spies (a regression we might catch — e.g., "if someone reorders `cache.set` and `network.post` in CanonicalPositionWriter, this snapshot would fail"). Skeleton FIRST.

Do NOT commit. Do NOT push. Stage for the integrator.
