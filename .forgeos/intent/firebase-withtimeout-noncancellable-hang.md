---
name: firebase-withtimeout-noncancellable-hang
created: 2026-07-21
author: claude-opus-4-8
---

**ADR refs:** none recorded for the `architecture`/`testing` areas touching
FirebaseManager's timeout utility.

## Context

`RemoteFeatureFlagsTests.testFetchIfNeeded_doesNotCrash` timed out at exactly
120.000s in a full-suite CI run (a second, distinct hang-class polluter surfaced
now that #1305 made CI fail-closed; the first was DeviceLogCollector). Chain:
`fetchIfNeeded → fetchAndActivate → FirebaseManager.fetchAndActivateRemoteConfig
→ withTimeout(10s) { remoteConfig.fetchAndActivate() }`.

`withTimeout` is supposed to bound the fetch at 10s, but it uses
`withThrowingTaskGroup`, which **awaits all child tasks before the group
returns**. When the timeout child wins the race, `cancelAll()` fires — but
Firebase's `fetchAndActivate()` ignores cancellation, so exiting the group blocks
on the still-running operation child anyway. The advertised bound is a no-op for
exactly the non-cancellable call it exists to bound: the caller hangs (120s in
CI; on a dead network the app's flag fetch would hang past the intended 10s in
production too). The existing guard test uses `Task.sleep` (which honors
cancellation), so it passes and masks the bug.

## Claims

- migrates `FirebaseManager.withTimeout` from a `withThrowingTaskGroup` race to a
  continuation-based first-wins race that orphans (does not await) the operation
  task on timeout, so a non-cancellable operation cannot block the caller past
  the bound — matching the method's own documented "orphaned fetch completes
  harmlessly in the background while the caller proceeds" contract
- adds `RemoteFeatureFlagsTests.testWithTimeout_boundsANonCancellableHangingOperation`
  pinning the bound against an operation that never completes AND ignores
  cancellation (the real Firebase case the existing `Task.sleep`-based test
  cannot reproduce)

## Anti-claims

- does NOT change `withTimeout`'s success-path or fast-return behavior
- does NOT change `fetchAndActivateRemoteConfig`, `fetchIfNeeded`, or any flag
  values / defaults
- does NOT touch DeviceLogCollector (that hang is fixed separately, PR #1314)
- does NOT touch any auth / DRM / borrow / download / sync path

## Files in scope

- Palace/AppInfrastructure/FirebaseManager.swift
- PalaceTests/AppInfrastructure/RemoteFeatureFlagsTests.swift
