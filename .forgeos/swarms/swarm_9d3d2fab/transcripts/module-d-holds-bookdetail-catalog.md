# Module D — Holds/BookDetail/Catalog — transcript

**Worktree:** `.claude/worktrees/swarm_9d3d2fab-d-holds-bookdetail-catalog`
**Branch:** `swarm/swarm_9d3d2fab-d-holds-bookdetail-catalog`
**Base commit:** `40d3270e0` (scaffold)

## Lint baseline (before)

```
PalaceTests/Holds/HoldsViewModelTests.swift:635:FLAKE-002
PalaceTests/Holds/HoldsViewModelTests.swift:661:FLAKE-002
PalaceTests/Holds/HoldsViewModelTests.swift:700:FLAKE-002
PalaceTests/Book/BookDetailViewModelTests.swift:1453:FLAKE-002
PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift:388:FLAKE-003
PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift:398:FLAKE-003
PalaceTests/OPDS2/OPDSFeedServiceStateMachineTests.swift:115:FLAKE-003
PalaceTests/Reader2/TPPReaderTOCBusinessLogicTests.swift  (no violations — 10s timeouts below the 15s floor)
```

8 blocking lint violations across 4 files. Reader2/TPPReaderTOCBusinessLogicTests.swift had **zero** flagged violations
(linter floor is 15s; the file's 10s timeouts are not flagged) — left untouched per contract guidance.

## Migrations applied

### HoldsViewModelTests.swift (3 FLAKE-002 sites — L635, L661, L700)

Each site was the identical `DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }` +
`await fulfillment(of: [exp], timeout: 2.0)` pattern after a `NotificationCenter.default.post(name:
.TPPSyncFailed, ...)`. All three are async test methods asserting the post-notification observer state on
the VM.

Replaced each with `drainMainQueue()` (the helper enqueues a no-op and waits for FIFO ordering to drain
the main queue — the NotificationCenter observer's main-queue dispatch lands before the assertion).

### BookDetailViewModelTests.swift (1 FLAKE-002 site — L1453)

This is a **negative** assertion: the test posts a `.TPPBookProcessingDidChange` notification for a DIFFERENT
book ID, then drains the main loop to prove the VM under test is unaffected. The contract suggested
`awaitCondition` on registry published state, but there is no positive state to poll — we're asserting NO
change. `drainMainQueue()` is the right primitive for negative assertions: FIFO guarantees any incorrect
main-queue dispatch enqueued before our drain has run before the assertion.

Replaced `let drain = expectation(...); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { drain.fulfill() }; wait(for: [drain], timeout: 1.0)` with `drainMainQueue()` plus an explanatory comment about the negative-assertion case.

### CatalogRepositoryStaleWhileRevalidateTests.swift (2 FLAKE-003 sites — L388, L398)

Both sites used `await awaitCondition(timeout: 30.0) { ... }` — the file's private async `awaitCondition` helper
(not the global XCTestCase one) is fine; the 30s ceiling was the lint violation. The stale-while-revalidate
happy path completes in <0.3s (stubbed network, in-memory cache). Dropped both to `timeout: 5.0` and trimmed
the now-stale comments about "30s headroom under pre-push contention".

### OPDSFeedServiceStateMachineTests.swift (1 FLAKE-003 site — L115)

`await fulfillment(of: [fetchCompleted], timeout: 15.0)` — fetchCompleted fires immediately after the state
machine transitions via `account._setState(.detailsLoaded(details))`. The state-machine event-loop hop is
sub-second. Dropped to `timeout: 5.0`.

### Reader2/TPPReaderTOCBusinessLogicTests.swift — NOT touched

Linter returns zero blocking violations on this file (10s timeouts are below the 15s lint floor). Per
contract: "**Only touch lines the linter flags** — don't speculatively drop timeouts that aren't blocking."
Left untouched.

## Lint result (after)

```
$ for f in PalaceTests/Holds/HoldsViewModelTests.swift \
        PalaceTests/Book/BookDetailViewModelTests.swift \
        PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift \
        PalaceTests/OPDS2/OPDSFeedServiceStateMachineTests.swift \
        PalaceTests/Reader2/TPPReaderTOCBusinessLogicTests.swift; do
    python3 scripts/lint-test-quality.py --per-file --file "$f" | grep -E ":(FLAKE|MISSING|FLUFF|TIMEOUT)-"
done
```

Result: **zero blocking violations across all 5 files.**

## Test execution

**Could not run in worktree due to build-infrastructure issue (not test-code related):**

The worktree's symlinked `ios-audiobooktoolkit` sub-project references `../Carthage/Build/AudioEngine.xcframework`
and the worktree's `Carthage -> /Users/mauricework/PalaceProject/ios-core/Carthage` symlink resolve to the
same physical xcframework via two distinct logical paths. Xcode 26 emits two `ProcessXCFramework` build tasks
producing the same output and fails with "Multiple commands produce '.../AudioEngine.framework'". The main
repo (no symlinks) builds the same test target cleanly; this is purely a worktree-Carthage-sub-project
interaction, independent of the test code edits in this module.

Verified the same test selector passes against develop in the **main repo** with the unmodified test code
(HoldsViewModelTests passed in 1.1s). The edits in this module are surgical (4 files, 8 sites, all
mechanical FLAKE-002/FLAKE-003 migrations following the helper contract) and were validated by the linter.

**Recommended integrator action:** when the integrator merges all 6 module branches, run the full test
suite from the main repo workspace (no worktree symlinks), which avoids the dual-path ProcessXCFramework
issue. `scripts/verify-pr.sh --quick` is the canonical gate per `plan.md` step #51 and runs from the
non-worktree checkout.

## Files modified (4)

```
PalaceTests/Book/BookDetailViewModelTests.swift           |  9 +++++----
PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift | 13 +++++--------
PalaceTests/Holds/HoldsViewModelTests.swift               | 15 +++++----------
PalaceTests/OPDS2/OPDSFeedServiceStateMachineTests.swift  |  2 +-
4 files changed, 19 insertions(+), 20 deletions(-)
```

Plus a `Carthage` symlink that I introduced for the test attempt (re-pointing to main repo Carthage); it
was already in the worktree pre-scaffold as a symlink to the same target — no net change. Submodule
gitlinks are pre-existing in the worktree.

## Constraints honored

- ✅ No `Palace/*` (production) edits.
- ✅ No new tests added.
- ✅ No `git commit` / `git push`.
- ✅ No force unwraps.
- ✅ Only touched files the linter flagged.
- ✅ Reader2/TPPReaderTOCBusinessLogicTests.swift left untouched (no lint violations).
