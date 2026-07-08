---
name: signin-await-account-readiness-basic-token-login
created: 2026-06-16
author: claude-opus-4-8
tracking: RC-CAMPAIGN w-auth-fix — confirmed 3.2.0 basic/token sign-in regression (build 476 signs in, 479 does not)
related_prs: []
---

# Intent: fix(signin): await account readiness on basic/token logIn() to end 3.2.0 silent no-op

## Problem

The 3.2.0 auth rewrite (build 479, HEAD a1384a0e9) regressed basic/token
sign-in. A fast (programmatic / quick-tap) "Sign in" that arrives BEFORE the
account's `authentication_document` has finished loading is a SILENT no-op:
the `/patrons/me` network request never fires, no error is surfaced, and the
UI does not change. Build 476 signs in; build 479 does not. A human typing
manually signs in fine — only fast/automated input fails — which is the
signature of a load-readiness race.

Root cause (pinned at 479 HEAD by source review + diagnostic-logged sim run):
`TPPSignInBusinessLogic.logIn(with:)` guards

```swift
guard let wrapped = selectedAuthentication else { return }
```

The `selectedAuthentication` getter resolves to `nil` whenever the library
account's `loadState` has not yet reached `.detailsLoaded`, because it reads
`loadedAccountDetails?.auths` (the Bucket A state-machine-aware read). So a
sign-in tap that races the auth-document fetch resolves the auth to `nil` and
returns silently — no `TPPIsSigningIn`, no network call, no UI feedback. The
`canSignIn` view-model guard passes (it returns `true` for basic auth even
when `selectedAuthentication` is nil), so the trip point is exclusively the
`logIn()` guard. The `Account.LoadState` / `awaitReady()` machine added in
3.2.0 migrated the synchronous read sites but never adopted the async
readiness gate at the user-initiated `logIn()` entry point the ADR
(`docs/architecture/account-state-machine.md`) named for it.

## Claims

- `logIn(with:)` no longer drops a sign-in tap when `selectedAuthentication`
  is `nil`: it calls `awaitReadyThenRetryLogIn(with:)`, which awaits the
  existing `Account.awaitReady()` readiness gate and re-invokes `logIn(with:)`
  once details are `.detailsLoaded`.
- Fast path preserved: when details are already loaded, `awaitReady()` returns
  immediately, so manual sign-in (where the auth document loaded long before
  the user typed) is behaviorally unchanged.
- Bounded: an `isAwaitingReadinessForLogIn` re-entrancy guard makes the
  await-then-retry happen at most once per tap, so `.detailsFailed` /
  `.detailsEvicted` (where the auth stays nil) cannot loop. On those terminals
  the helper posts `TPPIsSigningIn = false` so the UI is not left spinning.
- Browser-based auth (OAuth / OIDC / SAML) is dispatched before this guard in
  the view model and is unaffected.

## Anti-claims

- Does NOT change the synchronous read sites (`selectedAuthentication` getter,
  `makeRequest`, `isSamlPossible`, etc.) — they keep their Bucket A nil-
  tolerance. Only the user-initiated `logIn()` *action* gains the readiness
  await.
- Does NOT add a parallel sign-in path or new credential-collection mechanism.
  It reuses the existing `Account.awaitReady()` gate and re-enters the existing
  `logIn(with:)` switch.
- Does NOT alter manual sign-in timing or behavior: the fast path of
  `awaitReady()` (details already `.detailsLoaded`) returns synchronously, so
  no extra latency or UI state is introduced for the common case.
- Does NOT touch browser-based auth (OAuth / OIDC / SAML), token-refresh,
  sign-out, or DRM activation.
- Does NOT retry indefinitely: the re-entrancy guard caps the await-then-retry
  at one per tap; `.detailsFailed` / `.detailsEvicted` clear the signing-in
  state instead of looping.

## Files in scope

- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` — replace the silent
  `logIn()` guard with `awaitReadyThenRetryLogIn(with:)`; add the
  `isAwaitingReadinessForLogIn` re-entrancy guard.
- `PalaceTests/SignInLogic/TPPSignInBusinessLogicStateMachineTests.swift` —
  add `testLogIn_racingAuthDocLoad_firesRequestOnceReady` + the
  `singleBasicAuthDetails()` helper.
- `PalaceTests/Mocks/NYPLNetworkExecutorMock.swift` — add `executedRequestURLs`
  capture so the regression test can assert the credential request fired.

## Regression test

`TPPSignInBusinessLogicStateMachineTests.testLogIn_racingAuthDocLoad_firesRequestOnceReady`
drives `logIn()` while `loadState == .detailsLoading` (the race window) using
a single-basic-auth `AccountDetails`, asserts no request fires while loading,
then transitions to `.detailsLoaded` and asserts the credential request fires
(0 → 1, hitting `/patrons/me`). Verified it FAILS on the pre-fix silent-return
guard and PASSES with the fix. Adds an `executedRequestURLs` capture to
`TPPRequestExecutorMock`.

## Verification

- Automated A1QA staging sign-in 3/3 PASS on a fresh sim (iPhone 16 Pro /
  iOS 26.0); `/patrons/me` fired each run; each reached "Sign out".
- Sign-in unit suites green: `TPPSignInBusinessLogicStateMachineTests` (10),
  `TPPSignInBusinessLogicTests` (18), `TPPSignInBusinessLogicExtendedTests`
  (58), OAuth (11), SignOut (11).
