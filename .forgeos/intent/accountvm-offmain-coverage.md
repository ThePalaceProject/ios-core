---
name: accountvm-offmain-coverage
created: 2026-07-13
author: Maurice Carrier
branch: fix/accountvm-offmain-coverage
priority: critical-path (SignInLogic / auth-state) — coverage follow-up to #1222
---

# Intent: regression-lock the off-main account-change fix + make AccountDetailViewModel's signed-in derivation mutation-testable

## Context

Crashlytics issue `2aea34ee` (build 485 / 3.3.0, EXC_BREAKPOINT) was a Swift 6
main-actor isolation trap: `.TPPUserAccountDidChange` is posted on a BACKGROUND
queue (token-refresh path: `TPPNetworkResponder → setAuthState →
notifyAccountDidChange`), and `AccountDetailViewModel.setupObservers()`'s
`@MainActor`-isolated Combine sink was entered off-main. **PR #1222 (2026-07-08)
already fixed the crash** by adding `.receive(on: RunLoop.main)` to all four
subscribers — verified absent from all post-#1222 field builds.

The gap this intent closes: that fix has **zero regression test**, and the file's
signed-in derivation (`accountDidChange()`) is un-mutation-testable because the
credential snapshot comes from `accountsManager.userAccount(for:).credentialSnapshot()`
— a concrete `AccountsManager` returning a real keychain-backed `TPPUserAccount`,
so existing tests (1171 LOC) construct via `.production()` and kill 0/4 mutants.

## Claims

- Adds ONE injectable seam to `AccountDetailViewModel`'s designated initializer:
  `credentialSnapshotProvider: ((String) -> TPPUserAccount.CredentialSnapshot)? = nil`,
  defaulting (`nil`) to the existing production path
  `accountsManager.userAccount(for: id).credentialSnapshot()`. Mirrors the existing
  `drmAuthorizerProvider` injection pattern already on this init.
- Routes the three in-VM `credentialSnapshot()` call sites (init:150,
  accountDidChange:571, :602) through the resolved provider so tests can feed a
  controlled snapshot without keychain.
- Adds a regression test that drives `.TPPUserAccountDidChange` **posted from a
  background queue** through the real observer and asserts the state update lands
  on the main actor without trapping — the structural lock on #1222's
  `.receive(on: RunLoop.main)` (remove it → off-main `@MainActor` sink entry →
  Swift 6 trap → test killed).
- Adds behavioral tests for `accountDidChange()`'s signed-in derivation
  (`hasCredentials && authState != .loggedOut`, barcode/pin population vs clear)
  driven via the notification seam, killing the mutants on that derivation.

## Anti-claims

- Does NOT change the crash fix from #1222 (`.receive(on:)` stays); this is
  test + seam only.
- Does NOT change any production caller — the new init param is defaulted; the
  convenience init and `AccountDetailView.swift` are untouched.
- Does NOT alter `accountDidChange()`'s observable behavior — only the SOURCE of
  the snapshot becomes injectable.
- Does NOT attempt to kill the `canSignIn`/401-handler auth-TYPE mutants
  (`isOauth/isOidc == true` @80-82/414-415, `httpStatusCode == 401` @785): those
  need a separate `businessLogic.selectedAuthentication` seam and are DEFERRED to
  a tracked follow-up (see Deferred).

## Deferred

- Auth-type/401 survivor mutants require injecting `businessLogic`'s auth
  definition — a larger SignInLogic seam. Tracked as follow-up, not in this diff.
- Mutation kill-rate evidence must be produced by a LOCAL `palace_mutate.py` run
  (mutation is local-only per CLAUDE.md; CI does not run it). This branch's CI
  proves build + full-suite green only.

## Files in scope

- `Palace/Settings/AccountDetailViewModel.swift` (seam: ~10 LOC)
- `PalaceTests/ViewModels/AccountDetailViewModelTests.swift` (new tests)
