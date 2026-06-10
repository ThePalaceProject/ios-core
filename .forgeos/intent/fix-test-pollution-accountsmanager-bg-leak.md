# Intent: fix test pollution — AccountsManager background-load flag leak

## Problem

`AccountsManager.deferInitialLoadCatalogsForTesting` is a process-wide mutable
static flag that gates whether `AccountsManager.init` spawns its background
`loadCatalogs` Task. The test-safe value is `true` (no background work);
`PalaceTestSetup.bootstrap()` pins it `true` at bundle load. Tests that
genuinely need the background load to fire (`AppContainerResetTests`) opt in by
setting it `false` in their own setUp.

Two sites leave the flag `false` AFTER they run, leaking the unsafe value
forward to subsequent test classes:

1. `AppContainer._resetForTesting()` (`AppContainer.swift:505`) — runs after
   **every** test via `PalaceSingletonResetObserver.testCaseDidFinish`. It sets
   the flag `false` as its last step.
2. `AppContainerResetTests.tearDown()` (`AppContainerResetTests.swift:32`) —
   explicitly sets the flag `false` "so other tests see production semantics."

Once leaked `false`, a later test class that constructs an `AccountsManager`
(directly or via an incidental `AppContainer.production()`) spawns the
background registry crawl (1100+ libraries, network, layout). That stray task
outlives the test and pollutes whatever runs next.

Observed CI failures, all traced to this single leak (none are caused by the
diffs of the PRs they blocked — #1052, #1053, #1054):

- `AccountsManagerCancellationTests.testCancelBackgroundWork_onOptOutInstance_isSafeNoOp`
  — opt-out handle non-nil (failed all 3 iterations).
- `CatalogCacheKeyAndIsolationTests.testInMemoryCache_AfterSystemMemoryWarning…`
  — "Modifications to the layout engine must not be performed from a background
  thread" (NSInternalInconsistencyException).
- `BookReturnCleverReauthTests` — crash/restart → `** TEST FAILED **` with 0
  reported test failures.
- `TokenRefreshOnForegroundTests` / `TokenRefreshAndRetryQueueTests` —
  token/network state bleed.

## Claims

- `AppContainer._resetForTesting()` leaves `deferInitialLoadCatalogsForTesting`
  in the test-safe state (`true`), not `false`.
- `AppContainerResetTests.tearDown()` leaves the flag `true`, not `false`.
- A regression test pins the post-reset invariant: after `_resetForTesting()`
  the flag is `true`.

## Anti-claims

- No change to production runtime behaviour. The flag is only ever non-default
  inside an XCTest process (its initializer keys off `XCTestConfigurationFilePath`);
  `_resetForTesting()` already early-returns outside XCTest.
- No change to `AccountsManager.init`, `cancelBackgroundWork()`, or the
  background `loadCatalogs` path itself.
- Does not touch the three blocked PRs' branches — they rebase on develop after
  this lands.

## Files in scope

- `Palace/AppInfrastructure/AppContainer.swift`
- `PalaceTests/AppInfrastructure/AppContainerResetTests.swift`
