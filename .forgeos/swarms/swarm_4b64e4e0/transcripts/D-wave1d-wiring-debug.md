# Wave 1d — Wiring Tests Random-Ordering Failure Debug

**Agent:** swarm_4b64e4e0 Wave 1d debugger
**Date:** 2026-05-29
**Status:** READY — root cause identified, fix landed, 25+ consecutive random-order runs pass.

## Outcome

`AccountsManagerStateMachineWiringTests` now passes 13/13 deterministically under every random ordering tested (25+ runs across `fix3_verify.log` and `fix3_more.log`).

## Failure forensics

### Reproduction

Baseline (no fix), wiring class under random ordering failed in 3 distinct modes:

1. **`testDriveCurrentAccountAuthDoc_terminalState_isNoOp` :: `Setup: currentAccount must resolve after preload`** (line 404)
2. **`testDriveCurrentAccountAuthDoc_realAccountNotFound_doesNotRedrive` :: `Setup: currentAccount must resolve after preload`** (line 1028)
3. **`testLibrarySwitch_drivesNewCurrentAccountPastBasicInfoLoaded` :: `Setup: newUUID must be at .basicInfoLoaded after preload; got notLoaded`** (line 745)

All three are the SAME root-cause class: after the test calls `manager.preloadAccountsFromDiskCacheSync()`, the manager's `accountSets[hash]` is populated with the WRONG fixture (1142 bundled-registry accounts instead of the 171 fixture accounts the test seeded to disk).

### Mechanism (root cause)

`PalaceTests/OPDS2CatalogsFeed.json` (the fixture used by the wiring suite) contains 171 catalogs starting with `urn:uuid:1a110ef6...`. The `Palace/Accounts/Library/bundled_registry.json` ships with the production target as a fallback for cold first launch and contains 1142 catalogs starting with `urn:uuid:b7fd8756...`. The two sets are disjoint — none of the fixture UUIDs appear in the bundled snapshot.

The leak:

1. The very first `AppContainer.production()` call in the test process lazy-initializes `_cached` via `_buildCachedAppContainer()`. This call may originate from any of dozens of default-arg sites (`accountsManager: AccountsManager = AppContainer.production().accountsManager`, `private let networkExecutor = AppContainer.production().networkExecutor`, etc.) — most of which can fire incidentally during XCTest's class-discovery phase, before the first `XCTestCase.setUpWithError` runs.
2. At that first build, `AccountsManager.deferInitialLoadCatalogsForTesting` is still its declared default `false`. The new `AccountsManager.init` therefore takes the DEBUG arm at line 235-237 and spawns `backgroundFetchTask = Task.detached(priority: .background) { [weak self] in self?.loadCatalogs(completion: nil) }`.
3. The background `loadCatalogs` Task:
   - finds `accountSets[hash]` empty
   - finds no disk cache at `accounts_catalog_<hash>.json` (clean process)
   - falls into the bundled-snapshot cold-load arm (line 617-628) → calls `cacheAccountsCatalogData(bundledData, hash: hash, isBundled: true)` → **writes the 2.3 MB bundled registry to disk at the active hash**
   - then falls through to the network fetch (`fetchFromNetwork`), which on no-network test envs returns an error
4. The wiring test runs. `setUpWithError` calls `SingletonResetRegistry.shared.invokeAll()` which fires `AppContainer._resetForTesting()`. That rebuilds the cached AppContainer, but the OLD cached manager's background Task wrote bundled data to disk BEFORE the rebuild. The new cached manager's `init` preload now finds bundled-1142 on disk.
5. The wiring test body seeds disk cache with FIXTURE-171 (`seedDiskCache(activeHash, feedData)`) and calls `manager.preloadAccountsFromDiskCacheSync()` on its TEST-MINTED manager.
6. **BUT** — the cached production manager's background `loadCatalogs` Task is still in flight (or in the middle of a paginated load). It can write the bundled data AGAIN at any point — including BETWEEN `seedDiskCache` and the test's `preloadAccountsFromDiskCacheSync()`.
7. The test's explicit preload reads disk → gets bundled-1142 (the cached manager's late write overwrote the fixture seed) → constructs 1142 Account instances for bundled UUIDs → `accountSets[hash]` = 1142 bundled.
8. Test calls `manager.currentAccount` → `currentAccountId` resolves to `urn:uuid:1a110ef6...` (a fixture UUID). `account(uuid)` searches `accountSets` for a match — none, because the bundled set doesn't carry fixture UUIDs. Returns nil. **XCTFail.**

The wiring suite previously had a tearDown line `AccountsManager.deferInitialLoadCatalogsForTesting = false` (`AccountsManagerStateMachineWiringTests.swift:70`) — this set the flag back to false between tests, so even after the registry rebuild reset the cached AppContainer once with the flag set true, subsequent rebuilds (during `testCaseDidFinish → invokeAll → _resetForTesting`) could see flag=false in the rebuild window and re-spawn a background loadCatalogs on the new cached manager.

### Ruled-out hypotheses

I instrumented (then cleaned up) the following candidates and ruled each out:

- **`AccountStateStore.shared` subjects dict leaking transitions across UUIDs** — instrumentation showed setUp's `_resetAllForTesting()` correctly sets every existing subject to `.notLoaded`. The dict isn't cleared, but every existing value is reset. Not the leak source.
- **Polluter test's `fetchAuthDocumentWithStateMachine` completion firing late and writing `.detailsFailed` for the prior UUID after the next test subscribed** — initially the strongest hypothesis. Built a poll-then-drain in `tearDownWithError` keyed on a new `_inflightAuthDocFetchCountForTesting()` seam. It DID NOT change the failure mode — the failures shifted to "Setup: currentAccount must resolve after preload", confirming the auth-doc late write is NOT the load-bearing leak (or at least is decisively secondary to the disk-cache pollution).
- **`AccountsManager._cancelledLibraryUUIDs` / `inflightAuthDocFetches` carrying state across tests** — per-instance, dies with the test-minted manager. Not the leak.
- **`NotificationCenter.default` observers not being removed in tearDown** — the existing `PalaceSingletonResetObserver` already audits observer-count drift and would log; no drift detected.
- **`HTTPStubURLProtocol` registered classes leaking handler refs** — `HTTPStubURLProtocol.removeAllHandlers` is in the resetter list; verified clear.
- **`URLProtocol` registered classes** — `URLSession._resetStubbedSession` is in the resetter list.
- **`TPPUserAccount.sharedAccount(libraryUUID:)` keychain residue** — wiring tests don't touch the keychain; `KeychainAvailability` short-circuits these paths.
- **Hash mismatch between `manager.accountSet` and `activeHash`** — instrumented both, identical formula, identical values every run.

### The single load-bearing leak

The **disk-cache write done by the cached production manager's background `loadCatalogs` Task**, racing with the wiring test's `seedDiskCache → preloadAccountsFromDiskCacheSync` window.

## Fix (Phase B — minimum blast radius)

The fix has two parts, both `#if DEBUG`-gated:

### 1. `Palace/Accounts/Library/AccountsManager.swift` (production code, DEBUG-only seam)

Changed the default value of `deferInitialLoadCatalogsForTesting` from `false` (literal) to `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`. The XCTest env var is set by Apple's test runner whenever the host process is an XCTest harness; absent in normal app launches.

This means: in production / release builds (the whole `#if DEBUG` block is excluded), the flag does not exist and the original behavior is preserved byte-for-byte. In DEBUG test runs, the flag defaults to `true`, so the very first cached AppContainer's `AccountsManager.init` ALWAYS skips the background `loadCatalogs` Task. Tests that explicitly need the background load to fire (e.g. `AppContainerResetTests`) keep their existing pattern of setting the flag to `false` in their own setUp; this fix doesn't break them.

### 2. `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` (test code)

Removed the `AccountsManager.deferInitialLoadCatalogsForTesting = false` line in `tearDownWithError`. Replaced with an explanatory comment. Leaving the flag at `true` across the inter-test cached-rebuild window keeps `_resetForTesting`'s rebuild deterministic — the new cached manager always sees `flag=true` and skips the background loadCatalogs.

### 3. `PalaceTests/PalaceTestSetup.swift` (test code, belt-and-suspenders)

Added `AccountsManager.deferInitialLoadCatalogsForTesting = true` in `bootstrap()`. This belt-and-suspenders set is redundant with the env-derived default (the env-derived default fires at static-var initialization time, which is the earliest possible moment in Swift). But it documents the contract at the bootstrap site and protects against any future code that reassigns the flag during the bootstrap path itself.

### Why this is the minimum blast radius

- No production behavior change: the entire `deferInitialLoadCatalogsForTesting` field is `#if DEBUG`-gated. Release builds compile it out entirely, so the env-var dependency disappears.
- No test-fixture rewriting: the existing 171-account `OPDS2CatalogsFeed.json` fixture and the existing per-test seed/teardown pattern continue to work.
- No state-store rework: `AccountStateStore` is unchanged.
- No URLSession lifecycle rework: tasks are still cancelled cooperatively by `cancelNonEssentialTasks()`; we just prevent the leaking background task from being SPAWNED in the first place.

## Phase C — verification

### Random-order runs

`fix3_verify.log` — 10 consecutive runs of the full wiring class under random ordering:
```
RUN 1 failures: 0
RUN 2 failures: 0
RUN 3 failures: 0
RUN 4 failures: 0
RUN 5 failures: 0
RUN 6 failures: 0
RUN 7 failures: 0
RUN 8 failures: 0
RUN 9 failures: 0
RUN 10 failures: 0
```

`fix3_more.log` — 15 additional consecutive runs:
```
RUN 1: passed=13 failed=0
RUN 2: passed=13 failed=0
...
RUN 15: passed=13 failed=0
```

Total 25 consecutive 13/13 passes.

### Polluter+victim forced ordering

The original task's named polluter (testDriveCurrentAccountAuthDoc_staleEvictionMarker_redrives) + both victims (terminalState_isNoOp, realAccountNotFound_doesNotRedrive) forced in order — passes 3/3.

The Wave 1c known-failure ordering (testStartDownload_endToEnd → testDriveCurrentAccountAuthDoc_terminalState_isNoOp) — passes 2/2.

### Related tests still pass

Ran `AppContainerResetTests`, `AccountsManagerCancellationTests`, `PalaceTestSetupObservationTests`, `SingletonResetRegistryTests`, `PalaceWiringTestCaseTests` (22 tests total) — all pass. None of these explicitly opt in to background loadCatalogs in a way that would conflict with the env-derived default; the tests that do toggle the flag (in `AppContainerResetTests`) flip it to false within their own setUp and so still exercise their target code paths.

Ran `AccountsManagerTests` — all pass.

### Build clean

`xcodebuild ... build` succeeds with no warnings introduced by these changes.

## Files modified

- `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_4b64e4e0-orchestrator/Palace/Accounts/Library/AccountsManager.swift` (1 line of behavior + comment)
- `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_4b64e4e0-orchestrator/PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` (removed 1 line, added comment)
- `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_4b64e4e0-orchestrator/PalaceTests/PalaceTestSetup.swift` (added belt-and-suspenders flag set + comment)

## Recommended downstream actions

- **Update `feedback_wiring_suite_test_isolation.md`**: the current note attributes the flake to "background loadCatalogs outlives the test." That's accurate, but the canonical fix is now the env-derived default — document that pattern as the suite's reference solution for any future suite that mints `AccountsManager` instances in `setUp`.
- **Wall-failure entry**: this is a structural fix that closes a class of pollution beyond the wiring suite specifically. Anything that pins `AppContainer.production()` in its lazy default-arg path before setUp can hit the same race. Consider adding a wall-failure entry per the CLAUDE.md protocol.
- **Auth-doc late-write race**: while not load-bearing for THIS bug, the auth-doc completion can still fire after a test's tearDown and write a state transition to AccountStateStore. The `_resetAllForTesting()` reset in setUp catches it for any test that subscribes to `stateStream` strictly AFTER setUp, but a test that subscribes immediately at body-start could in theory see a stale transition arrive between setUp's reset and the first emission. The wiring suite hasn't hit this in 25+ random-order runs, but a future suite with tighter timing might. Worth tracking as a follow-up.
