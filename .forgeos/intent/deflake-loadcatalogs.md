---
name: deflake-loadcatalogs
created: 2026-07-28
author: claude-opus-4-8
---

**ADR refs:** none recorded for the touched accounts area in the local ledger;
this implements the Wave-3 brief §4 3a-(2) rewrite (PP-4754 root fix) as a
standalone change ahead of 3a. Front-runs, does not contradict, prior decisions.

PP-4754 root-cause de-flake: convert AccountsManager's leaky detached/GCD
background catalog-crawl work into owned, cancellable, deterministically-joinable
Tasks so the test-boundary drain is COMPLETE (no un-awaitable write channel
survives a test), and add a wall-clock-free join seam for tests. Production crawl
work (what it does, its ordering, snapshot writes, priorities, detachedness) is
behavior-identical; only ownership/cancellability/test-joinability change.

## Claims

- adds file `Palace/Accounts/Library/CatalogCrawlScheduler.swift` with `CrawlTaskScheduler` (injectable spawn seam) and `OwnedCrawlTaskRegistry` (self-pruning owned-task registry)
- adds field `ownedCrawlTasks` (OwnedCrawlTaskRegistry) to `AccountsManager`
- adds field `crawlScheduler` (CrawlTaskScheduler) to `AccountsManager`, injected via a defaulted `init` param
- adds public function `_awaitCatalogLoadForTesting(maxRounds:)` on `AccountsManager` (async, XCTest-gated Task-join, no wall-clock)
- adds field `_ownedCrawlTaskCountForTesting` on `AccountsManager`
- adds private function `spawnOwnedCrawlTask(priority:detached:firstRun:_:)` on `AccountsManager` routing every crawl spawn site through the registry
- migrates the init background-load arm from a `#if DEBUG` Task.detached / `#else` GCD split to a single owned `spawnOwnedCrawlTask` spawn (RELEASE: GCD -> detached Task, same .utility QoS)
- migrates the two untracked network-executor completions in `fallbackFetchFromNetwork` and `fallbackDirectRefresh` into owned Tasks bridging the callback via the async-throwing `GET`
- removes `_trackCrawlTask`
- removes `_trackedCrawlTasks`
- adds function `spawnOwnedCrawlTask` on `AccountsManager`
- migrates `cancelBackgroundWork` and `cancelAndDrainBackgroundWork` to drain the owned registry
- migrates `PalaceWiringTestCase.tearDownWithError` per-manager `cancelBackgroundWork()` to `cancelAndDrainBackgroundWork()`

## Anti-claims

- does NOT change what the crawl does (same registry crawl, pagination, preload, snapshot bytes, `.TPPCatalogDidLoad` posts, stale-while-revalidate branch order)
- does NOT change the public surface of `AccountsManager` beyond the defaulted `crawlScheduler` init param and the two new test-only seams (all 159 existing `AccountsManager(` constructions compile unchanged)
- keeps the existing observation surfaces unchanged in name and semantics (`_backgroundFetchTaskWasExplicitlyCancelled`, `_backgroundFetchTaskHandleIsNil`, `_injectBackgroundFetchTaskForTesting`, `fetchFromNetworkCountForTesting`, `_awaitAllCrawlTasksForTesting`, `deferInitialLoadCatalogsForTesting`)
- keeps `deferInitialLoadCatalogsForTesting` (not deleted)
- does NOT touch Wave-3 seams (S1 breaker inversion, S2 download protocols, S3 de-locatoring); `networkExecutor` lazy var stays as-is
- does NOT change `AppContainer._resetForTesting`'s structure (comment-only update)

## Files in scope

- Palace/Accounts/Library/CatalogCrawlScheduler.swift
- Palace/Accounts/Library/AccountsManager.swift
- Palace/AppInfrastructure/AppContainer.swift
- PalaceTests/Support/PalaceWiringTestCase.swift
- PalaceTests/Accounts/CatalogCrawlSchedulerTests.swift
- PalaceTests/Accounts/AccountsManagerCatalogLoadJoinTests.swift
- Palace.xcodeproj/project.pbxproj
- scripts/godclass-loc-baseline.txt
