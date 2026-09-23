---
name: wknavigationdelegate-mainactor-witness
created: 2026-07-07
author: claude-opus-4-8
---

## Context

The Xcode 26.2 WebKit SDK annotates `WKNavigationDelegate` (and its `decisionHandler`
blocks) `@MainActor` (`WK_SWIFT_UI_ACTOR`). Three delegate implementations declare
`webView(_:decidePolicyFor:decisionHandler:)` with a plain, non-`@MainActor`
`decisionHandler`, so the method only "nearly matches" the `@objc` optional requirement
and is NOT registered as the witness. WebKit's `-respondsToSelector:` then skips the
policy delegate entirely and default-allows every navigation — silently breaking
universal-links interception (web-sheet OAuth/SAML sign-in never completes) and external
`.linkActivated` handling in the bundled/remote HTML viewers. This reliably hangs
`SignInWebSheetIntegrationTests.test_navigatingToUniversalLinksURL_...` at its 30s timeout
on the current toolchain (it passed pre-toolchain-bump). Surfaced dogfooding the Swift 6
Phase C landing (PR #1199); this fix is independent of Phase C and fixes develop.

## Claims

- migrates `webView(_:decidePolicyFor:decisionHandler:)` (both navigationAction and
  navigationResponse overloads) in `SignInWebViewCoordinator` from `nonisolated` +
  `Task { @MainActor }` + `DecisionHandlerBox` to a plain `@MainActor` method with an
  `@escaping @MainActor` `decisionHandler` called synchronously (async cookie fetch stays
  in a `Task`), so it matches the SDK's `@MainActor` witness and WebKit invokes it
- removes the now-obsolete `DecisionHandlerBox` type from `SignInWebViewCoordinator`
- adds `@MainActor` to the `decisionHandler` parameter of the `decidePolicyFor`
  implementations in `BundledHTMLViewController` and `RemoteHTMLViewController`

## Anti-claims

- does NOT change the navigation-policy decision logic (`decideAction` / `decideResponse`
  matching is unchanged) or any observable sign-in behavior beyond restoring the
  policy-delegate invocation the SDK bump silently disabled
- does NOT touch `SignInWebSheetViewModel` or the pure decision-logic unit tests
- does NOT modify the `SWIFT_VERSION` / build settings (this is not the Phase C flip)
- does NOT alter the lifecycle delegate methods (`didStartProvisionalNavigation`, etc.)

## Files in scope

- Palace/SignInLogic/SignInWebViewCoordinator.swift
- Palace/Network/BundledHTMLViewController.swift
- Palace/Network/RemoteHTMLViewController.swift
- .forgeos/intent/wknavigationdelegate-mainactor-witness.md
