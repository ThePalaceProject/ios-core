---
name: fix-alert-presentation-test-hermeticity
created: 2026-06-11
author: claude-opus-4-8
tracking: test-hermeticity #2 (fleet) — alert-presentation leak class; sibling to WS-4. Post-3.2.0 fast-follow per palace-pm (Run B shows TPPAlertUtilsTests passes clean).
related_prs: []
---

# Intent: make TPPAlertUtilsTests self-hermetic (alert-presentation leak)

## Problem
`TPPAlertUtilsTests` has 4 tests that present a REAL `UIAlertController` on a
live, key `UIWindow` (`testCrashlyticsFE741015`,
`testRetryPresentation_AfterFirstAlertDismisses`,
`testRetryPresentation_ExceedsMaxRetries`,
`testPresentAlert_WhenNoAlertShowing`). Their cleanup (dismiss + `isHidden`)
lives in the test BODY and the class has NO `tearDown`. So if a test
fails/times out before its body cleanup — or a `presentFromViewControllerOrNil`
retry block (`DispatchQueue.main.asyncAfter`, exp backoff up to ~1.6s) fires
AFTER `waitForExpectations` returns — a presented alert leaks on a key window.
That window stays reachable via the SHARED
`(UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController()`
resolution, so a later nil-presenter `present` exhausts its 3 retries ("top
controller is still a UIAlertController").

This is a test-isolation leak, NOT a production bug. It is LATENT: it self-cleans
on the happy path and did not fail run A or run B deterministically; it surfaces
only under shuffle + asyncAfter-post-wait + a non-pristine runner.

## Approach (test-only)
Add a `tearDown` to `TPPAlertUtilsTests` that guarantees a clean shared UIKit
hierarchy regardless of how a test exited:
1. Drain the main run loop so pending `asyncAfter` retry blocks fire now.
2. Synchronously dismiss any controller still presented on the tracked root.
3. Release the window — `isHidden`, `rootViewController = nil`, `resignKey()`,
   drop `windowScene` — so a later test cannot resolve it as the top VC.
4. Final drain so a retry scheduled during dismissal also resolves against the
   now-empty hierarchy.
Window/root are tracked into instance properties via
`trackForHermeticTeardown(_:_:)` from each of the 4 presentation tests.

## Claims
- Adds `presentationWindow`/`presentationRootVC` instance props + `tearDown` +
  `trackForHermeticTeardown` + `drainMainRunLoop` to `TPPAlertUtilsTests`.
- The 4 window tests call `trackForHermeticTeardown(window, rootVC)` after
  `makeKeyAndVisible()`.

## Anti-claims
- NO production change (TPPAlertUtils / presentFromViewControllerOrNil untouched).
- Does NOT alter any test's assertions or the presentation/retry behavior under test.
- Does NOT chase a cross-class full-suite repro (the in-class focused repro is
  green in isolation; cross-class is the leftover, post-M0).

## Files in scope
- PalaceTests/ErrorHandling/TPPAlertUtilsTests.swift

## Validation
- RED-FIRST baseline: TPPAlertUtilsTests 45/0 green in isolation (no deterministic
  in-class polluter — confirms latent/cross-class).
- GREEN: same class green WITH the tearDown (self-resetting).
- Authoritative verify-pr.sh --quick: HELD until M0 Run B terminal verdict (per
  palace-pm guardrail; no contended cold build).
- Wall gates + SUT-grep run on the diff.
