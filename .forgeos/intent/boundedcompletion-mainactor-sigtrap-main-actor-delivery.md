---
name: boundedcompletion-mainactor-sigtrap-main-actor-delivery
created: 2026-07-28
author: claude-opus-5
tracking: HelpSpot #18414 (the seam being fixed); blocker for PR #1348
related_prs: [1348]
---

# Intent: fix boundedCompletion @MainActor SIGTRAP (forward-port blocker)

## Problem

`TPPSignInBusinessLogic.boundedCompletion` — the #18414 auth-doc GET timeout
seam — SIGTRAPs under Swift 6 on `develop`, crashing the test host:

```
EXC_BREAKPOINT / SIGTRAP
  _dispatch_assert_queue_fail
  _swift_task_checkIsolatedSwift
  closure #2 in static TPPSignInBusinessLogic.boundedCompletion(...)
  _dispatch_block_async_invoke2
```

`TPPSignInBusinessLogic` is `@MainActor` on `develop` (it is NOT on `main` —
that isolation is develop's Swift 6 work), so closures written inside
`boundedCompletion` **inherit main-actor isolation**. Both of its racers run
off-main: the timeout `DispatchWorkItem` on `timerQueue` (`.global()`), and the
operation callback on the URLSession delegate queue (`TPPNetworkExecutor` uses
`delegateQueue: nil`). Invoking a main-actor-isolated closure there is the
`swift_task_checkIsolated` trap.

This is introduced by the 3.2.1/3.2.2/3.2.3 forward-port merge (main's
`boundedCompletion` landing on develop's `@MainActor` type), so it is a defect
in the merge resolution rather than a shipping bug — 3.2.3 as it ships is
unaffected.

Two earlier attempts failed and are recorded so they are not retried: marking
the *test* closures `@Sendable` (the trap is inside `boundedCompletion`'s own
closure, so the fix must be in production), and hopping via
`Thread.isMainThread ? body() : DispatchQueue.main.async(execute: body)` inside
the work item (main THREAD is not the main-actor EXECUTOR; the trap fires on
closure *invocation*, before the body runs).

## Claims

- `boundedCompletion` now ALWAYS delivers `onTimeout` and `completion` on the
  main actor, whichever racer wins. The previous documented contract —
  "`completion` runs on the winning racer's thread" — was itself the defect.
- The timeout `DispatchWorkItem` closure is explicitly `@Sendable` so it stops
  inheriting `@MainActor`, and the operation-callback parameter becomes
  `@escaping @Sendable (T) -> Void` for the same reason.
- The caller's non-`Sendable`, main-actor-isolated closures cross that
  `@Sendable` boundary in a `TPPBoundedCompletionSink` `@unchecked Sendable`
  box (same pattern as `LibrariesSectionViewModel.UncheckedSendableBox`), and
  the work item crosses in `TPPWorkItemBox`. `TPPOnceGuard` becomes
  `@unchecked Sendable` (all state already lock-guarded).
- Exactly-once is unchanged: `TPPOnceGuard.claim()` is still checked
  synchronously on the winning racer's thread, before any hop.
- The now-redundant `DispatchQueue.main.async` at the sole production call site
  (`ensureAuthenticationDocumentIsLoaded`) is removed — it only ever protected
  that one call site and left the seam trapping for every other caller.
- `boundedCompletion` returns the timeout `DispatchWorkItem`
  (`@discardableResult`) so tests can deterministically join the LOSING racer
  via `notify` instead of sleeping past its deadline (STARVE-001).
- `TPPAnnotations` gains an XCTest-gated, per-call `DispatchGroup` join seam
  (`_awaitDeletionChainForTesting`) for `deleteAllBookmarks`'s fire-and-forget
  GET→chained-DELETE chain. Per-call rather than process-wide so an unjoined
  call in one suite cannot hang an `await` in another. `nil` outside XCTest, so
  production call sites are no-op `?.enter()` / `?.leave()`.

## Anti-claims

- No change to the timeout VALUE, the exactly-once guarantee, the `max(0,
  timeout)` clamp, or which value each racer surfaces.
- No change to `deleteAllBookmarks`'s deletion policy — the audiobook
  `.readingProgress` position is still preserved (see
  `cause2-deletion-is-ux-change-not-regression`); only chain tracking is added.
- No production behavior change from the `TPPAnnotations` seam: it is gated on
  `XCTestConfigurationFilePath` and allocates nothing in production.
- Does NOT extract `boundedCompletion` out of `TPPSignInBusinessLogic`. That
  extraction (~90 LOC of sign-in-agnostic primitive, which would net the hub
  back below its pre-forward-port LOC baseline) is a follow-up recorded in
  `scripts/godclass-loc-baseline.txt` — a forward-port merge must not also
  carry a decomposition move.
- Does NOT port D1 `serverAuthoritative` (still deferred).

## Files in scope

- `Palace/SignInLogic/TPPSignInBusinessLogic.swift`
- `Palace/Reader2/Bookmarks/TPPAnnotations.swift`
- `PalaceTests/TPPSignInBusinessLogicTests.swift`
- `PalaceTests/Sync/CrossDeviceSyncE2ETests.swift`
- `PalaceTests/MyBooks/BookReturnServiceTests.swift`
- `PalaceTests/Accounts/AccountStateMachineTests.swift`
- `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift`
- `scripts/godclass-loc-baseline.txt`
