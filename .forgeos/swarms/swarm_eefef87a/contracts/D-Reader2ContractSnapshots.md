# Module D — Reader2 contract-snapshot tests

**Improvement #4 from the A+ posture push.** Reader2 (Readium 3.x WKWebView) is XCTest-invisible. Contract snapshots pin the dependency-call surface without WKWebView introspection.

## In-scope files (exclusive write)

### Tests (new)
- NEW `PalaceTests/Contract/Reader2BookmarkContractTests.swift` — bookmark save → registry write call order
- NEW `PalaceTests/Contract/Reader2PositionResumeContractTests.swift` — position save → registry write + sync queue; reader-resumes-where-it-left-off
- NEW `PalaceTests/Contract/__Snapshots__/Reader2BookmarkContractTests/*.json` (per-scenario)
- NEW `PalaceTests/Contract/__Snapshots__/Reader2PositionResumeContractTests/*.json`

### Production (only if needed for testability)
- Reader2 source files in `Palace/Reader2/Bookmarks/` and `Palace/Reader2/BusinessLogic/` MAY get small seams (added `internal` initializers, exposed protocols, factory methods). Each seam must be:
  - Minimum scope (no new public surface unless explicitly noted)
  - Documented with `// testability seam for Reader2 contract snapshots` and a back-reference to this contract.

Bounded production files that may be touched (do not exceed this list):
- `Palace/Reader2/Bookmarks/TPPReaderBookmarksBusinessLogic.swift` (if its delegate isn't already injectable)
- `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` (already touched by `swarm_f4fbef9c` — confirm seams are already in place; reuse them)
- `Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift` (same — `swarm_f4fbef9c` introduced PositionWriter seams)

## OFF-LIMITS for this module

- `Palace/Network/`, `Palace/MyBooks/`, `Palace/Accounts/` (Module A)
- `Palace/Audiobooks/` (Module B)
- `scripts/verify-pr.sh`, `docs/architecture/` (Module C)
- The `CallLog` + `ContractSnapshot` helpers in `PalaceTests/Contract/` — read-only. The pattern is established. Do NOT modify them.
- `PalaceTests/Contract/Reader2PositionAdapterContractTests.swift` — already exists from `swarm_f4fbef9c`. Read it, don't edit it. Your new files are additive.

## Test contract (LOCKED)

### `Reader2BookmarkContractTests.swift` (≥3 scenarios)

```swift
final class Reader2BookmarkContractTests: XCTestCase {
    func test_bookmarkSave_writesToRegistry_thenAnnotations() throws {
        let log = CallLog()
        let spy = SpyBookmarkRegistry(log: log)
        let businessLogic = TPPReaderBookmarksBusinessLogic.makeForTest(registry: spy)
        businessLogic.addBookmark(at: locator)
        ContractSnapshot.assert(log, named: "bookmarkSave_writesToRegistry_thenAnnotations")
    }
    func test_bookmarkSave_failureFromRegistry_doesNotEnqueueAnnotation() throws { ... }
    func test_bookmarkDelete_removesFromRegistry_thenAnnotationsDelete() throws { ... }
}
```

### `Reader2PositionResumeContractTests.swift` (≥3 scenarios)

```swift
final class Reader2PositionResumeContractTests: XCTestCase {
    func test_positionSave_writesRegistryThenSyncQueue() throws { ... }
    func test_readerResume_loadsRegistryThenSynchronizer() throws { ... }
    func test_readerResume_synchronizerReturnsNewer_applies_andRecordsCrossFormatMapping() throws { ... }
}
```

## Behavior contract (LOCKED)

1. Snapshots use the existing `CallLog` + `ContractSnapshot` helper. First-run failures are expected — record then commit the JSON.
2. Tests do NOT touch WKWebView. They drive `TPPReaderBookmarksBusinessLogic` / `TPPLastReadPositionPoster` / `TPPLastReadPositionSynchronizer` through their public seams with spies on the registry + annotations + sync queue dependencies.
3. Each spy lives co-located in the test file (private final class), following the established `PalaceTests/Contract/README.md` pattern.
4. If a Reader2 production class doesn't have a testable init, ADD ONE — but minimally, with a `// testability seam for Reader2 contract snapshots` comment. Track every seam added in your transcript.

## Acceptance criteria

- Both new test files exist with ≥3 scenarios each (6 total).
- All 6 snapshot JSONs exist in `__Snapshots__/`, committed.
- Tests pass cleanly on a second run (record-then-pass is the snapshot-test workflow; the integrator must verify both runs).
- Any added production seam is documented in the transcript + has the `// testability seam` comment.
- `scripts/verify-pr.sh --quick` passes.
- No edits in off-limits list.

## Implementer prompt

You are Module D implementer for `swarm_eefef87a`. Read `PalaceTests/Contract/README.md` and the existing files in `PalaceTests/Contract/` to understand the established pattern (esp. `Reader2PositionAdapterContractTests.swift` from `swarm_f4fbef9c` — your work is adjacent, not duplicate).

**Step order:**
1. Write `transcripts/D-Reader2ContractSnapshots.md` skeleton FIRST.
2. Read `Palace/Reader2/Bookmarks/TPPReaderBookmarksBusinessLogic.swift` and `Palace/Reader2/BusinessLogic/TPPLastReadPosition{Poster,Synchronizer}.swift`. Identify the dependency seams. For each, decide: (a) already testable, or (b) needs a minimal seam.
3. Write the two test files. Snapshot first run will FAIL — that's the record path. Re-run with `CONTRACT_SNAPSHOT_RECORD=1` to write the JSON. Commit the JSON.
4. Run both files a second time. Must pass cleanly.
5. If a Reader2 production seam was added, document it in the transcript with file + line + before/after.
6. Run `scripts/verify-pr.sh --quick`. Should pass.
7. Fill out the transcript.

**No force unwraps.** Spy classes are `private final class`, co-located in the test file. Do NOT add a new "MockBookmarkRegistry" to `PalaceTests/Mocks/` — co-locate it.

**Reader2 is XCTest-invisible** — your tests must NOT instantiate any WKWebView or NavigatorViewController. If a scenario seems to require it, the scenario is wrong — re-frame around the dependency-call surface.

Do NOT commit. Do NOT push. Stage for the integrator.
