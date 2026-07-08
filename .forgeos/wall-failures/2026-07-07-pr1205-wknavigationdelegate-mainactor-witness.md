---
date: 2026-07-07
pr: "#1205"
source: shipped-bug
reviewer_ids: [rev_a70be5c0, rev_a42075fe]
changeset_id: ""
wall: hook
walls: [hook, reviewer]
severity: high
wall_status: proposed
applied_in: ""
detector_script: "scripts/check-objc-witness-nearly-matches.sh"
detector_status: queued
no-detector: ""
name: wall-failures-2026-07-07-pr1205-wknavigationdelegate-mainactor-witness
type: evolving
status: active
created: 2026-07-07
last_refresh: 2026-07-07
freshness_window: 365d
owners: [general]
description: A non-@MainActor decisionHandler made WKNavigationDelegate.decidePolicyFor "nearly match" the @MainActor SDK witness — WebKit silently skipped the policy delegate, breaking web-sheet sign-in on Xcode 26.2
---

# WKNavigationDelegate `decidePolicyFor` silently de-registered as `@objc` witness on the Xcode 26.2 SDK

## Finding (verbatim from the compiler + CI)

Compiler (build log, emitted but not gated):
```
warning: instance method 'webView(_:decidePolicyFor:decisionHandler:)' nearly matches
optional requirement 'webView(_:decidePolicyFor:decisionHandler:)' of protocol 'WKNavigationDelegate'
note: candidate has non-matching type '(WKWebView, WKNavigationAction, @escaping (WKNavigationActionPolicy) -> Void) -> ()'
```
CI symptom (PR #1199 build-and-test): `SignInWebSheetIntegrationTests.test_navigatingToUniversalLinksURL_firesLoginCompletionWithCookies` — reliable 30s timeout ("Restarting after unexpected exit, crash, or test timeout").

## What actually happened

The Xcode 26.2 WebKit SDK annotated `WKNavigationDelegate` **and its `decisionHandler` blocks** `@MainActor` (`WK_SWIFT_UI_ACTOR`). Three delegate implementations — `SignInWebViewCoordinator` (from the Phase B `complete`-mode sweep, which had marked the methods `nonisolated` + boxed the handler through a `Task { @MainActor }` hop) plus `BundledHTMLViewController` and `RemoteHTMLViewController` — declared `webView(_:decidePolicyFor:decisionHandler:)` with a **non-`@MainActor`** `decisionHandler`.

Because `WKNavigationDelegate` methods are `@objc` **optional** protocol requirements, a signature that doesn't match the imported requirement isn't a hard conformance error — Swift just doesn't register the method as the witness and emits a *warning* ("nearly matches"). At runtime WebKit's `-respondsToSelector:` returns false for the policy-decision selector, so WebKit **skips the policy delegate and default-allows every navigation**. Web-sheet OAuth/SAML sign-in never intercepts its universal-links callback (login never completes); the bundled/remote HTML viewers stop routing external links to the OS.

It looked correct because: (a) it compiled (optional requirement, warning not error); (b) it worked fine on the *older* SDK where the protocol was still `nonisolated` — the Phase B change was valid then; (c) the only functional coverage is a real-WKWebView integration test, which merely *timed out* rather than failing an obvious assertion.

## Walls that should have caught it (and why they didn't)

- **hook / verify-pr**: no gate treats the compiler's `"nearly matches optional requirement"` warning as blocking. This warning is the *exact, authoritative* signal that an `@objc` optional-protocol witness has drifted from its requirement — and it was printed on every build, ignored.
- **reviewer** (Phase B): the reviewer who approved marking the delegate methods `nonisolated` did not flag that a future SDK annotating the protocol `@MainActor` would silently de-register the witness. Reasonable to miss — the SDK change was in the future — which is exactly why the structural (compiler-signal) gate matters more than reviewer vigilance here.
- **TDD/mutation**: N/A — the behavior *was* covered by `SignInWebSheetIntegrationTests`; that wall worked, but only fired when the SDK bumped, and only as a timeout (easy to dismiss as a flake — which it initially was).

## Proposed permanent fix

**Gate on the compiler's own signal.** Add a CI/tooling check that fails when the build log contains `nearly matches optional requirement` for any `@objc` protocol method (`WKNavigationDelegate`, `WKUIDelegate`, `UICollectionViewDelegate`, `CPTemplateApplicationSceneDelegate`, etc.). This catches the entire class — any optional `@objc` witness whose signature/isolation drifts from the SDK requirement — not just this instance.

- `scripts/check-objc-witness-nearly-matches.sh <build-log>` — greps for `nearly matches optional requirement`, prints the offending file:line + the `candidate has non-matching type` note, exits non-zero. Wire into `scripts/xcode-test-optimized.sh` / `verify-pr.sh` post-build.
- pytest in `scripts/tests/` with a fixture build log containing a nearly-matches warning (blocks) and one without (clean-path passes), per green-board contract #4.
- CLAUDE.md note under the Swift 6 section: *"`nearly matches optional requirement` on an `@objc` delegate is never benign — it means the method is not the witness and the delegate callback will be silently skipped. Match the SDK's isolation exactly (`@MainActor` method + `@escaping @MainActor` handler for `WK_SWIFT_UI_ACTOR` protocols)."*

Note: this is broader than Swift 6 — the same class of bug can appear any time an SDK changes an `@objc` optional requirement's signature. The gate is toolchain-durable.
