# CP-D3 (FirstRunDecode) — implementer transcript

Swarm swarm_27c181b5, Wave C. Branch `swarm/swarm_27c181b5-waveC`.

## Summary

Fixed the cold-first-launch bug where the bundled 2.4 MB library-registry
snapshot was decoded on the **main thread** and potentially **twice** (init
background arm + `TPPAppDelegate.presentFirstRunFlowIfNeeded` @MainActor caller),
because the dedupe `addLoadingHandler` guard sat *after* the bundled branch in
`AccountsManager.loadCatalogs`.

Applied the Phase-1a-corrected fix (the naive "move the dedupe up" regresses
first-run by swallowing the network fetch):

1. **Consolidated the dedupe** — a SINGLE `addLoadingHandler` guard placed ABOVE
   the bundled branch (so a concurrent second caller short-circuits before the
   decode) and deliberately NOT re-checked before `fetchFromNetwork`. Removed the
   now-redundant second guard. The bundled branch's completion stays `_ in`
   (does not clear handlers); handler clearing still happens only on network
   completion via `callAndClearLoadingHandlers` inside `fetchFromNetwork`.
2. **Hopped the bundled decode off-main** — the bundled snapshot load + cache
   write + `loadAccountSetsAndAuthDoc` + the `fetchFromNetwork` kickoff now run
   inside a tracked `Task.detached(priority: .utility)` (`firstRunTask`), tracked
   via `_trackCrawlTask` so `cancelBackgroundWork()` cancels it and the
   `Task.isCancelled` fixture-seed guard stays meaningful.
3. **Bumped both init crawl QoS arms** `.background` → `.utility`: the DEBUG arm
   (`Task.detached(priority:)`) and the release arm
   (`DispatchQueue.global(qos:)`), so DEBUG tests exercise the same QoS as prod.

TPPAppDelegate was intentionally NOT edited: the AccountsManager self-hop makes
the on-main caller's decode off-main at the source, so a redundant caller-side
dispatch would be double-hop noise. The off-main property is now intrinsic to
`loadCatalogs` (and is what test 3 drives directly).

## Files changed

- `Palace/Accounts/Library/AccountsManager.swift`
  - `loadCatalogs`: consolidated dedupe + off-main `firstRunTask` hop (removed
    the redundant pre-`fetchFromNetwork` guard).
  - Both init arms: `.background` → `.utility` (+ updated the two now-stale
    `.background` doc comments).
  - Two env-gated (NOT `#if DEBUG`, mirroring `_trackCrawlTask`'s
    `_isRunningUnderXCTest` gate — blast-radius BR-2-clean) test-observability
    seams: `var snapshotResourceResolver: BundleResourceResolving = Bundle.main`
    (injectable bundled-snapshot loader, reusing the existing
    `BundledRegistrySnapshot.load(resolver:)` injection pattern) and
    `fetchFromNetworkCountForTesting` (env-gated counter incremented at
    `fetchFromNetwork` entry).
- `PalaceTests/Accounts/AccountsManagerFirstRunDecodeTests.swift` (NEW) — 3 tests.
- `Palace.xcodeproj/project.pbxproj` — test file registration (via
  `ruby scripts/pbxproj_add_swift.rb`).

Scope: only the bundled-snapshot branch + dedupe consolidation + crawl QoS were
touched. D1's `preloadAccountsFromDiskCacheSync` / slim hydration /
`slimAccountsByUUID` were NOT touched.

## Tests (PalaceTests/Accounts/AccountsManagerFirstRunDecodeTests.swift)

Subclass of `PalaceWiringTestCase` (inherits `SingletonResetRegistry` reset,
`deferInitialLoadCatalogsForTesting=true`, `cancelBackgroundWork()` on every
helper-minted manager in tearDown, Application-Support catalog-cache purge). Each
test injects a `CountingSnapshotResolver` stub into `snapshotResourceResolver`
that records the decode's invocation count + thread and returns a tiny empty
OPDS2 feed (no 2.4 MB real snapshot, no per-account network for the bundled leg).
Isolated `UserDefaults` suite per test so `currentAccountId` can't flip the
manager onto the warm path.

1. `testSecondConcurrentLoad_shortCircuitsBeforeBundledDecode` — two sequential
   loads; the barrier-ordered dedupe registration makes the second short-circuit
   before the bundled branch. Asserts the stub resolver ran exactly once
   (`assertForOverFulfill` + `callCount == 1`).
2. `testFirstRun_networkFetchStillFiresOnce_afterBundledDecode` — **the
   Phase-1a-critical one.** Asserts `fetchFromNetworkCountForTesting` reaches
   exactly 1 after the bundled decode, and the bundled decode ran once first.
3. `testFirstRun_bundledDecode_runsOffMainThread` — drives `loadCatalogs` from
   the main test thread; asserts the stub resolver's recorded
   `lastCallOnMainThread == false`.

## Verification (sim 141BD227-6E9A-4409-8D99-2D4FE818238D, iPhone 16 Pro)

- **Full class, correct code (fresh derivedData):** `** TEST SUCCEEDED **` —
  `Executed 3 tests, with 0 failures` in 0.563s. No timeout/restart lines. No
  `AccountsManager.swift` compile errors.
- **Network-fetch-still-fires evidence (regression proof):** injected the
  Phase-1a regression (swallow `fetchFromNetwork` under XCTest) and rebuilt on a
  **fresh** derivedData →
  `testFirstRun_networkFetchStillFiresOnce_afterBundledDecode` **FAILED**:
  `XCTAssertTrue failed - Network fetch must fire after the bundled decode` and
  `XCTAssertEqual failed: ("0") is not equal to ("1")`, failing at the 5.7s
  timeout. Mutation reverted; final code re-verified green. (Note: the first two
  bare-`return` mutation attempts spuriously "passed" on stale incremental
  binaries — confirmed by the absence of the unreachable-code warning; a
  guaranteed-fresh derivedData gave the correct FAIL. Build-cache lesson logged.)

## Definition-of-Done evidence

1. SUT instantiation — `check-test-name-vs-body.py` on the new test file: `OK,
   0 fake-wiring tests`, exit 0. Manager constructed via `makeFreshAccountsManager`
   (same discipline as the D1 `AccountsManagerLaunchSnapshotTests`).
3. Multi-step body — test 1 literally drives two `loadCatalogs` calls.
5. Mutation — regression-injection proof above (network-fetch-swallow killed by
   test 2). This is the contract's required network-fetch-still-fires evidence.
6. Build — `** TEST SUCCEEDED **` (full class, fresh DD). verify-pr.sh full-suite
   is the integrator's gate.
9. Blast-radius — `check-blast-radius.py --diff <d3.diff> --quiet` exit 0 (seams
   are internal + env-gated, no new public API, no `#if DEBUG` on prod paths).
11. Superpartner — `check-superpartner-spectrum.py --diff <d3.diff> --quiet`
    exit 0. Adjacency — `check-adjacency-staleness.py` exit 0.

## Note for integrator

Accidental cross-checkout hazard hit and cleaned up mid-task: the first edit pass
landed in the shared **main** checkout (`/Users/mauricework/PalaceProject/ios-core`,
detached HEAD) instead of the worktree — the documented worktree-CWD hazard.
Reverted every accidental edit there via the Edit tool (git was blocked) and
confirmed `git status --porcelain` on main shows only unrelated pre-existing
state; all CP-D3 changes live solely in the worktree.
