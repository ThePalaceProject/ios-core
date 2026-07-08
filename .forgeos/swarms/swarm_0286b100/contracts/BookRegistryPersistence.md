# Contract: BookRegistryPersistence  [CRITICAL PATH]  (root cause C)

## Root cause (production concurrency bug)
`save(for:)` serializes its `write(to:.atomic)` through `diskWriteQueue` (`BookRegistrySync.swift`
~495-510), but `saveSync(for:)` writes DIRECTLY on the calling thread, bypassing `diskWriteQueue`
(~515-533). So a final `saveSync` can run its atomic write concurrently with an in-flight
`diskWriteQueue.async` write to the same URL — two `.atomic` rename-replaces race and a stale
snapshot can clobber the final one. The test's comment ("saveSync blocks until all prior enqueued
writes flush") is FALSE because saveSync never enqueues onto diskWriteQueue. Victim:
TPPBookRegistryPersistenceTests.testConcurrentSaves_ProduceValidJSONOnDisk.

## Required fix (ROOT CAUSE — not a mask)
Route `saveSync(for:)` through the SAME serialization domain: wrap its body in `diskWriteQueue.sync { }`
and take the registry snapshot INSIDE that closure (so async and sync saves share one FIFO domain).
After this the test's stated invariant becomes TRUE by construction. Preserve the per-account snapshot
capture (PP-4129 cross-account contract) and the `.atomic` write. Do not alter `save(for:)`'s contract.

## Files in scope
- `Palace/Book/Models/BookRegistrySync.swift`  (saveSync only)
OFF-LIMITS: everything else, including the store/registry mutation paths.

## Test contract
- testConcurrentSaves_ProduceValidJSONOnDisk passes deterministically in the FULL suite.
- Mutation: `python3 scripts/palace_mutate.py --file Palace/Book/Models/BookRegistrySync.swift --tests PalaceTests/TPPBookRegistryPersistenceTests --diff-only` ≥50% diff-scoped.

## Verification criteria (grep-able)
- `grep -n 'diskWriteQueue.sync' Palace/Book/Models/BookRegistrySync.swift` ≥ 1.
- `timeout: 10.0` in testConcurrentSaves UNCHANGED.
- No Task.sleep / usleep / asyncAfter added to the test.
- No XCTSkip.
- Mutation kill-rate pasted; FULL-suite green tail under `-test-timeouts-enabled YES`.
