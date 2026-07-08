---
name: epub-reading-resume-double-restore
created: 2026-06-14
author: claude-opus-4-8
tracking: 3.2.0 regression run — EPUB reading-resume bounce (saved/synced position restore); no dedicated Jira ticket
related_prs: ["#981 (regressing change — added the post-paint gate but left the constructor restore in place, commit 7612d2312)"]
---

# Intent — EPUB reading-resume double-restore: single restore authority

3.2.0 must-fix (found by the regression run, confirmed by w-stabilize): restoring
a real saved/synced reading position bounces the EPUB reader back to My Books (the
"Sync Reading Position" dialog → Stay/Move → WKWebView WebContent torn down).
Never-read / page-1 books open fine.

## Root cause (traced in code + reconciled with w-stabilize's behavioral data)
A saved locator is restored TWICE: (1) the `EPUBNavigatorViewController` constructor
`initialLocation:` applies it DURING WKWebView first-paint
(`TPPEPUBViewController.swift:71-75`), and (2) the post-first-paint gate
`ReaderInitialLocationNavigator.go(to:)` applies it again from `viewDidAppear`
(`TPPBaseReaderViewController.swift:347`). The constructor restore fires before
Readium's location-mapping table is populated — the exact failure
`ReaderInitialLocationNavigator` was built to avoid. For a SERVER-sourced
cross-device locator that during-first-paint restore can't resolve → "Failed to
determine navigation direction for scroll" → WebContent teardown → bounce. (A local
page-N locator survives it, which is why single-device reopen is fine — the
discriminator is the locator's source/values, the trigger is the during-first-paint
constructor restore. The sync path adds no separate `go(to:)`; the synced position
becomes the `initialLocator` via `ReaderService.makeEPUBViewController:577`.)

## Claims (this diff does exactly these)
1. Makes the post-first-paint gate the SINGLE restore authority:
   `TPPEPUBViewController.navigatorConstructorInitialLocation(forSavedLocation:)`
   returns nil, so the navigator constructor never restores; the gate restores once
   post-paint (after the location-mapping table is populated). Wired at the
   `EPUBNavigatorViewController(initialLocation:)` call site.
2. Hardens the gate (`ReaderInitialLocationNavigator`): checks `go(to:)`'s Bool
   result; on false sets `restoreDidDegradeToStart` + logs "remaining at start
   (page 1)" — so a future unresolvable locator is a graceful page-1 degradation
   (the navigator is already at its natural start), observable in prod, NOT a
   teardown. Adds an `onRestoreAttempt` test hook for deterministic, no-sleep tests.
3. Extends `TPPBaseReaderViewControllerInitialLocationTests`: the sync-condition
   exactly-one-restore test (was RED at 2 → now 1), never-read=0, go-false→degrades,
   go-true→no-degradation.

## Anti-claims
- Does NOT change the synchronizer, the Sync dialog, `convertToLocator`, the
  position-save format, or the gate's existing latch/attach/ready semantics.
- Does NOT attempt to fix any underlying "server-shaped locator fails to resolve"
  issue (if w-stabilize's re-run lands at page 1 rather than the synced page, that
  residual is a SEPARATE follow-up — out of scope here; this PR removes the
  crash/bounce). Likely full restore expected (timing, not shape, per analysis).
- No build-number bump (release gate intact).

## Files in scope
- `Palace/Reader2/UI/TPPEPUBViewController.swift`
- `Palace/Reader2/UI/ReaderInitialLocationNavigator.swift`
- `PalaceTests/Reader2/TPPBaseReaderViewControllerInitialLocationTests.swift`
