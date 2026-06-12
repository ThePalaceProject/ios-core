---
name: ws0-crawl-drain-fix
created: 2026-06-11
author: claude-opus-4-8
---

## Summary

WS-0 follow-up completing the defer-flag class: close the "auth-state-bleed"
120s main-thread-deadlock board-red. A `deferInitialLoadCatalogsForTesting=false`
test (`AppContainerResetTests`) leaves a background `loadCatalogs` crawl that
`_resetForTesting`'s cooperative cancel does not DRAIN, so the crawl still holds
the `accountSetsLock` `.barrier` when the next `@MainActor` reauth does a
synchronous `.sync` read → deadlock → 120s hang. Make the cancel synchronous
(drain the crawl, pumping the run loop) at every test boundary. All seams are
`#if DEBUG` (compiled out of release) → zero production-runtime change.

## Claims

- adds `AccountsManager.cancelAndDrainBackgroundWork(timeout:)` (#if DEBUG) — cancels then DRAINS the in-flight crawl/fetch tasks while pumping the main run loop, bounded by timeout, with `[WS0-DRAIN]` telemetry on >=50ms or ceiling-hit
- changes `AppContainer._resetForTesting()` to call `cancelAndDrainBackgroundWork()` instead of `cancelBackgroundWork()` so the orphan crawl is drained at every test boundary (order-independent, global)
- makes the `RuntimeQuiescenceGateTests` pool-probe red-first self-test hermetic (8×cores blockers + retry-needing-one-timeout) so it is not flaky

## Anti-claims

- does NOT change any production-RUNTIME behaviour — both touched seams (`cancelAndDrainBackgroundWork`, `_resetForTesting`) are `#if DEBUG`, compiled out of release
- does NOT modify `cancelBackgroundWork()` (its behaviour is pinned by `AccountsManagerCancellationTests`)
- does NOT fix the 2 separate residual victim classes (LocalFileAdapter keychain-auth-state, DeviceLogCollector OSLog) — routed to their owners
- does NOT change the AccountsManager concurrency model / lock semantics

## Files in scope

- Palace/Accounts/Library/AccountsManager.swift
- Palace/AppInfrastructure/AppContainer.swift
- PalaceTests/MetaTests/RuntimeQuiescenceGateTests.swift
- .forgeos/intent/ws0-crawl-drain-fix.md (NEW)
