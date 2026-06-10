# Contract: AccountStateStore-Isolation  (root cause A — KEYSTONE)

## Root cause
`Account.awaitReady()` (`Account+State.swift`) parks on `for await state in stateStream`, backed by
the process-wide singleton `AccountStateStore.shared`. A test that drives an account to the
non-terminal `.detailsLoading` and starts an `awaitReady()` Task, then ends without a terminal
transition, leaks that Task forever: the teardown reset `_resetAllForTesting()` sends `.notLoaded`
(non-terminal), so the `for await` loop hits `continue` and stays parked; `Task.checkCancellation()`
only re-evaluates on the next emission, which never comes. Leaked awaiters accumulate across the
suite and starve the Swift cooperative pool. Victims: CatalogPreloader >60s hang (#1), OPDS
blocksUntilLoaded 5s flake (#3), DownloadThrottling pauseAll flake (#4). `awaitReady` has 16
production consumers → "different victim each run."

## Required fix (ROOT CAUSE — not a mask)
Add a terminal teardown drain to `AccountStateStore` that RESOLVES every parked awaiter at the test
boundary (finish the per-UUID streams and/or emit a terminal eviction so every `for await` loop in
`awaitReady()` returns). Wire it into the existing `SingletonResetRegistry` entry in
`PalaceTestSetup.swift` so it fires after EVERY test, replacing the non-terminal `.notLoaded` reset
semantics. The production `awaitReady()` live-path semantics MUST NOT change (it already throws
`CancellationError` on stream termination — preserve that).

## Files in scope
- `Palace/Accounts/Library/AccountStateStore.swift`  (add terminal drain / finishAllForTesting)
- `Palace/Accounts/Library/Account+State.swift`       (ensure awaitReady returns on stream finish)
- `PalaceTests/PalaceTestSetup.swift`                 (registry wiring of the drain)
OFF-LIMITS: every other file. Do NOT touch the 16 awaitReady consumers.

## Test contract
- New test: drive account → `.detailsLoading`, start an `awaitReady()` Task, invoke the teardown
  drain, assert the Task COMPLETES (does not stay parked).
- Victims pass in a FULL-suite run: CatalogPreloaderTests.testPreloader_PreloadsRecentlyUsedAccounts_UpToLimit,
  OPDSFeedServiceStateMachineTests.testFetchLoansFeed_blocksUntilLoaded_thenFetches,
  DownloadThrottlingServiceTests.testPauseAllDownloads_suspendsAllNonAudiobookTasks.

## Verification criteria (grep-able, proves NOT a mask)
- No new XCTSkip: `git diff origin/develop -- PalaceTests | grep -c XCTSkip` == 0.
- Victim timeouts UNCHANGED vs origin/develop.
- No `Task.sleep` added to victims.
- The drain is terminal: the new drain calls a stream-finish / terminal emit (`continuation.finish()`
  / terminal `.detailsFailed` / eviction), NOT `setState(.notLoaded`.
- `awaitReady` still returns on stream finish (CancellationError preserved on the live path).
- Validated against the FULL suite with `-test-timeouts-enabled YES`.
