---
name: test-flake-hardening-cancel-leaked-registry-crawl-continuation
created: 2026-06-10
author: claude-opus-4-8
tracking: (none — CI flake-hunt follow-up to PR #1056; unblocks PRs #1052/#1053/#1054)
related_prs: []
---

# Intent: test flake hardening — cancel leaked registry crawl + continuation + tight timeouts

## Problem

After #1056 fixed the `deferInitialLoadCatalogsForTesting` flag leak, CI was
still intermittently red — a **different** test crashing each run
(BookReturnCleverReauth, CatalogCacheKeyAndIsolation, BookReturnServiceAuthCoordinator,
AudiobookPlaytimesLifecycle, ErrorLogExporter), plus assertion flakes that
passed on retry but rode a crashed run to red. Root: `loadCatalogs` →
`fetchFromNetwork` / `refreshInBackground` spawn **unstructured `Task { }`**
blocks (registry crawl, pagination, catalog preload) that are NOT children of
`backgroundFetchTask`, so `cancelBackgroundWork()` never cancelled them. A test
that builds an `AccountsManager` under `deferInitialLoadCatalogsForTesting = false`
(`AppContainerResetTests`) leaked a live multi-page network crawl that
CPU-starved and crashed whatever ran next.

Secondary fragilities surfaced by the contention:
- `testCancelBackgroundWork_onLiveInstance_cancelsTheTask` used
  `withCheckedContinuation { _ in }` and never resumed it → leaked continuation
  ("SWIFT TASK CONTINUATION MISUSE"), a suspended-forever task lingering in the
  process.
- `BearerTokenAdapterTests` (2.0s) and `ActiveSessionsViewModelTests` (0.5s)
  used tight expectation timeouts that flaked under CI CPU starvation (one took
  18s then passed at 0.5s on retry).
- `ErrorLogExporterTests.testPP3651` called `collectLogsForPreview()` →
  `DeviceLogCollector.collectLogs(lastDays: 7)`, a 7-day OSLogStore enumeration
  that hangs in a log-saturated CI process and exceeded the per-test timeout.

## Claims

- `AccountsManager` tracks the unstructured crawl/pagination/preload tasks in a
  DEBUG-only registry; `cancelBackgroundWork()` cancels all of them.
- No production runtime change: the registry and cancellation are `#if DEBUG`,
  and `cancelBackgroundWork()` is only ever invoked under `_resetForTesting()` /
  wiring-suite tearDown — release builds never track or cancel.
- The leaked continuation is replaced with a cancellation-aware
  `try? await Task.sleep(nanoseconds: .max)`.
- `BearerTokenAdapterTests` timeout 2.0s→10.0s; `ActiveSessionsViewModelTests`
  0.5s→5.0s (CI-safe ceilings; green path still fulfills in ms).
- `ErrorLogExporterTests.testPP3651` exercises `collectDeviceInfo()` directly
  (made `internal`) instead of `collectLogsForPreview()`, asserting the same
  Patron-ID behavior without the OSLogStore enumeration.

## Anti-claims

- No change to the registry-crawl logic, network layer, or what `loadCatalogs`
  fetches. Only adds DEBUG-only cancellation reach.
- Does not touch the three blocked PRs' branches — they rebase on develop after
  this lands.
- Does not bound/limit `DeviceLogCollector` OSLogStore collection in production
  (separate concern; the real-user export-logs slowness is noted but out of
  scope here).

## Files in scope

- `Palace/Accounts/Library/AccountsManager.swift`
- `Palace/Logging/ErrorLogExporter.swift`
- `PalaceTests/Accounts/AccountsManagerCancellationTests.swift`
- `PalaceTests/Audiobook/Vendors/BearerTokenAdapterTests.swift`
- `PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift`
- `PalaceTests/Logging/ErrorLogExporterTests.swift`
