---
name: fix-bookreturn-inflight-task-iuo-race
created: 2026-06-10
author: claude-opus-4-8
tracking: (none — latent crash surfaced by CI flake-hunt on PR #1053)
related_prs: []
---

# Intent: fix BookReturnService in-flight-task IUO data race (return-path crash)

## Problem

`BookReturnService` tracks fire-and-forget Tasks for cancellation in
`inFlightTasks`. Both `launchTrackedTask` and `launchTrackedMainActorTask` used:

```swift
var task: Task<Void, Never>!
task = Task { [weak self] in
    await body()
    self.inFlightTasks.remove(task)   // <-- reads the IUO from inside the body
}
inFlightTasks.insert(task)
```

The Task body runs on a **different executor** than the launch site that
assigns `task`. The read of the `var task` IUO inside the body is an
**unsynchronized cross-thread read**: under CPU load the assignment is not yet
visible to the body's thread, so the implicit unwrap finds nil and traps —
`Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional
value` at the `inFlightTasks.remove(task)` line. Intermittent (race-window-
dependent), and it crashed `BookReturnServiceContractTests.test_returnBook_authError_triggersReauth`
on CI on the legacy reauth path. The same crash can hit a real user returning a
book while a reauthentication is in flight.

## Claims

- `inFlightTasks` becomes `[UUID: Task<Void, Never>]`, keyed by a per-launch
  `UUID` token.
- Both launch helpers capture the **value-typed** `UUID` (Sendable) in the
  auto-removal closure and remove by key — the closure no longer references the
  launch-site `task` handle, eliminating the cross-thread IUO read. `task` is
  now a plain `let`.
- `cancelAllInFlightTasks`, `inFlightTaskCount`, and
  `inFlightTasksSnapshotForTesting()` preserve their existing behavior /
  signatures (snapshot still returns `Set<Task<Void, Never>>`).

## Anti-claims

- No change to the return flow, reauth path, cancellation contract, or the
  set of Tasks that get tracked/cancelled. Pure data-structure + capture change.
- No public API change (`inFlightTasksSnapshotForTesting` still returns a Set).

## Files in scope

- `Palace/MyBooks/BookReturnService.swift`
