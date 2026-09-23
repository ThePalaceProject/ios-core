---
name: swift6-apptarget-signin-targeted
created: 2026-06-30
author: Maurice Carrier
branch: swift6/apptarget-signin
initiative: Swift 6 app-target Wave 1 — SignInLogic slice (critical-path: auth)
priority: critical-path
---

# Intent: Swift 6 `targeted` strict-concurrency — SignInLogic slice

## Context

App-target Wave 1: `SWIFT_STRICT_CONCURRENCY = targeted` is set on develop
(warnings, `SWIFT_VERSION` stays 5.0). This slice drives the `Palace/SignInLogic/`
files to zero `targeted` concurrency warnings, fixing by isolation only (never
`nonisolated(unsafe)`). Auth is a critical path. CI is the build gate (no local
DRM-app build possible).

## Claims

- Removes the `= SignInModalSheetPresenter.productionDriver` default argument from
  `SignInModalSheetPresenter`'s designated init (the only `productionDriver`
  default-arg reference; no caller relied on it — convenience init + all tests
  pass `driver:` explicitly).
- Moves the `WKNavigationAction.request` / `WKNavigationResponse.response` reads
  in `SignInWebViewCoordinator` from the nonisolated delegate body into the
  existing `Task { @MainActor in }` hop.
- Makes `TPPReauthenticator` a `final class … @unchecked Sendable` (it now
  conforms to PalaceAuth's `Sendable`-refined `Reauthenticating`) and serializes
  its `authenticateCallCount` behind an `OSAllocatedUnfairLock` (replacing the
  stored `var`). Adds `import os`.
- Replaces the self-capturing `await MainActor.run { … }` hops in
  `TPPSignInBusinessLogic.awaitReadyThenRetryLogIn` and
  `TPPSignInBusinessLogic+CardCreation.startRegularCardCreation` with the file's
  existing `TPPMainThreadRun.asyncIfNeeded { … }` main-hop; the re-entrancy guard
  is cleared at the end of the main-thread work on both paths (replaces the
  `defer`).

## Anti-claims

- Does NOT change any shared/cross-file type (`TPPUserAccount`, `Account`,
  `TPPBook`, protocols, `TPPNetworkExecutor`, etc.).
- Does NOT make `TPPSignInBusinessLogic` `@MainActor` (would ripple cross-module
  into MyBooks/BookDetail/etc.).
- Does NOT change the foreign-host 401 / `currentAccountHostsProvider` auth-error
  behavior.
- Does NOT use `nonisolated(unsafe)` or `MainActor.assumeIsolated`.
- Does NOT change observable sign-in/reauth behavior — isolation/mechanism only.

## Files in scope

- Palace/SignInLogic/SignInModalSheetPresenter.swift
- Palace/SignInLogic/SignInWebViewCoordinator.swift
- Palace/SignInLogic/TPPReauthenticator.swift
- Palace/SignInLogic/TPPSignInBusinessLogic.swift
- Palace/SignInLogic/TPPSignInBusinessLogic+CardCreation.swift
