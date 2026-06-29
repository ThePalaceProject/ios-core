---
name: hermeticity-leaker-accountdetail-vm
created: 2026-06-29
author: claude
type: bugfix
---

# hermeticity-leaker-accountdetail-vm

Residual test-hermeticity hang class behind the #1122 flaky-CI block (post-3.2.0
WS-0 stabilization). NOT the defer-flag class (gated) and NOT pool-starvation
(probe ruled it out). Roots a main-thread CPU-saturation hang that reds the board
on unlucky shuffles.

## Claims

<!-- Fix scope is being confirmed with palace-pm before the production-touching
parts land; the investigation (Reproduction / Root cause) is complete. -->

- removes `MallocStackLogging` + `PrefersMallocStackLoggingLite` from the
  `Palace.xcscheme` Test action — an accidental Diagnostics-tab leftover that
  instruments every allocation with a backtrace, the amplifier that turns the
  O(accounts) account-iteration into a >120s hang (spindump-proven ~50% of the
  hot-loop leaf time is `stack_logging_lite_malloc`). Test-config only, zero
  production change.
- closes the real-network escape: `TPPNetworkExecutor`'s URLSession bypasses
  `NoNetworkURLProtocol` (which only catches `URLSession.shared`), so
  `AccountsManager.fallbackDirectRefresh → networkExecutor.GET` hits real
  `registry.palaceproject.io/libraries` in unit tests (CI log: 67s elapsed,
  -1001 timeouts) — driving the loadCatalogs churn. [DESIGN PENDING — critical-path]
- stops the leaked-observer class: an `AccountDetailViewModel` survives its test
  with active `@MainActor` `.TPPCurrentAccountDidChange` observers that re-run
  O(~1142-account) `setupTableData` on every account-change post. [DESIGN PENDING]

## Anti-claims

- does NOT change production runtime behaviour of `TPPNetworkExecutor`'s real
  network path (only test-time protocol registration / session injection).
- does NOT alter the defer-flag quiescence gate or the crawl-drain fix (#1066).
- does NOT change `AccountsManager` lock semantics.

## Files in scope

- Palace.xcodeproj/xcshareddata/xcschemes/Palace.xcscheme (MallocStackLogging removal)
- PalaceTests/NoNetworkURLProtocol.swift / PalaceTests bootstrap (executor session coverage) — TBD
- Palace/Settings/AccountDetailViewModel.swift (leaked observer) — TBD pending design
- PalaceTests/ViewModels/AccountDetailViewModelTests.swift (teardown / test AppContainer) — TBD

## Reproduction

REAL artifact = PR #1122 CI run 28384882381 (build-and-test FAILED, 33m). Two
order-dependent HANGS, persisting across iters-3 retries (NOT retry-masked):
- `TPPSettingsTests.testUseBetaLibraries_publishesViaCombine` (killed @120s)
- `CatalogPreloaderTests.testPreloader_PreloadsRecentlyUsedAccounts_UpToLimit` (@60s)
Decisive: 17 `[WS0-POOL-DIAG]` lines ALL `completed=true` (max 421ms) + 0
defer-flag breadcrumbs ⟹ neither pool-starvation nor defer-flag class.

Reproduced LOCALLY at iters-1 no-retry, full suite, single-process, random order
(`scripts/repro.sh` analogue via `harness test -- test-without-building
-test-timeouts-enabled YES -default-test-execution-time-allowance 120`): a fresh
shuffle hung `EPUBSearchViewModelTests.testClearSearch_ResetsState` (victim
varies by shuffle — all victims are async/main-thread-dependent tests).
`AccountDetailViewModelTests` PASSES in isolation (19 tests / 1.0s) → the hang is
environment-dependent pollution, not a self-contained bug.

## Root cause

Spindump of the hung test-host (Palace pid 93263, captured live during the
EPUBSearch hang): the MAIN THREAD is 100%-busy (3654/3654 samples), NOT blocked
on a lock — a CPU-bound runaway, not a deadlock:

  Main Thread
   AccountDetailViewModel.setupObservers() sink closure  (AccountDetailViewModel.swift:193)
    → accountDidChange()                                 (:581)
     → setupTableData()                                  (:281)
      → accountInfoSection()                             (:317)
       → AccountsManager.account(_:) → performRead → accountSetsLock.sync
        → accountSets.values.first{contains(where:uuid)}.first(where:uuid)  (O(n) over ~1142 bundled accounts)
         → ~50% leaf time in MallocStackLogging (stack_logging_lite_malloc / thread_stack_pcs)

Mechanism (multi-factor):
1. A test creates `AccountDetailViewModel` against `AppContainer.production()`
   (real shared AccountsManager). The VM survives past its test scope (in-flight
   async init work: `loadInitialData`'s `Task { @MainActor … }` captures self
   strongly; `ensureAuthenticationDocumentIsLoaded` keeps the chain alive on a
   slow real-network auth-doc load). Its `.TPPCurrentAccountDidChange` /
   `.TPPUserAccountDidChange` `@MainActor` observers stay subscribed.
2. The shared AccountsManager loads the BUNDLED 1142-account snapshot → every
   `account(uuid)` lookup is O(~1142).
3. Background churn keeps posting `.TPPCurrentAccountDidChange` / re-running
   loadCatalogs (104× "Loading catalogs from cache" in the CI run), driven in
   part by the real-network escape: `TPPNetworkExecutor`'s session is NOT covered
   by `NoNetworkURLProtocol` (only `URLSession.shared` is), so
   `fallbackDirectRefresh → networkExecutor.GET` hits real network (60s+ CI
   timeouts) and retries.
4. Each churn post re-fires the leaked VM observer → O(1142) main-thread
   `setupTableData`, AMPLIFIED by scheme-enabled MallocStackLogging → main thread
   saturated for >120s → whatever async/main test runs next hangs and is killed.

## Verification

<!-- TBD: reproduce hang reliably (baseline), apply fix, show full suite green
twice at iters-1 with the hang eliminated; spindump no longer shows the
AccountDetailViewModel observer hot-loop. -->
