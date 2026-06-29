---
name: fe741015-alert-presented-during-active-transition
created: 2026-06-29
author: claude-opus-4-8
type: bugfix
tracking: Crashlytics fe741015 — #1 production crash on 3.1.0 (478), 122 events / 36 users / 14d. develop-only fix (3.2.0 RC frozen per palace-pm).
related_prs: []
---

# Intent: fe741015 — alert presented during active transition (coordinator-wait)

## Claims
- Replaces the *sample-once-then-retry-or-drop* `transitionCoordinator` guard in
  `TPPAlertUtils.presentFromViewControllerOrNil` (both the explicit-presenter and
  topmost-VC paths) with a coordinator-*wait*: when a transition is in flight,
  present only from `coordinator.animate(alongsideTransition:)`'s completion,
  re-walking to the settled hierarchy — mirroring the proven pattern already in
  `TPPPresentationUtils.safelyPresent`.
- Defers the announcement self-chain in `TPPAnnouncementBusinessLogic.alert(...)`
  (presenting `nextAlert` from the previous alert's dismiss handler) onto the main
  queue so the dismiss transition settles before the next present.
- Makes the launch-time sync-reading-position prompt in
  `TPPLastReadPositionSynchronizer` coordinator-aware instead of a raw
  `topVC.present`, preserving the continuation (the alert is always presented,
  never dropped).

## Anti-claims
- Does NOT touch the `isBeingPresented`/`isBeingDismissed` / already-presenting
  retry paths (those remain short-backoff retries for states the coordinator
  does not cover).
- Does NOT add a process-level uncaught-exception handler (the durable fix is to
  prevent the throw, not catch the deferred one — the existing `NS_NOESCAPE`
  `TPPObjCExceptionCatcher` cannot trap a `_UIAfterCACommitBlock` throw anyway).
- Does NOT address the dormant "Failed to determine navigation direction for
  scroll" sub-variant grouped under the same Crashlytics issue (0/25 recent
  events — tracked separately if it resurfaces).
- No `#if DEBUG` on production code.

## Files in scope
- Palace/ErrorHandling/TPPAlertUtils.swift
- Palace/Accounts/User/Announcements/TPPAnnouncementBusinessLogic.swift
- Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift
- PalaceTests/RegressionGuards/UIAlertCACommitGuardTests.swift (regression guard)

## Reproduction
- Real artifact: Crashlytics fe741015, 25/25 most-recent events (build 478,
  iOS 26.5) are `NSInternalInconsistencyException: "A view controller not
  containing an alert controller was asked for its contained alert controller"`,
  thrown inside a deferred `_UIAfterCACommitBlock` →
  `+[UIAlertController _alertControllerContainedInViewController:]`. All stacks
  truncate above UIKit; 6/25 carry the breadcrumb chain *proactive token refresh
  → 401 → marking credentials stale*, the rest end in `[OPDS2-DIAG]` catalog-load
  logs — i.e. an alert presented during the launch catalog/sign-in-modal
  transition.
- simdrive repro (gating, see Verification): force a 401 on the first catalog
  request at cold launch so the invalid-credentials alert is surfaced while the
  catalog/tab-bar transition is still animating.

## Root cause
A `UIAlertController` is presented while a sibling VC transition is in flight.
UIKit defers the alert's own transition into the next CA commit; by then the
presentation-controller relationship is inconsistent and UIKit throws. The
existing hardening did not close it for two verified reasons: (1) the guard
*sampled* `transitionCoordinator == nil` once and then presented synchronously,
racing the deferred CA commit; (2) `TPPObjCExceptionCatcher` takes an
`NS_NOESCAPE` block and only wraps the synchronous `present()`, so the deferred
`_runAfterCACommitDeferredBlocks` throw escapes it. Several launch alerts also
bypassed the helper via raw `present()`. The guard commit (e185f3f8b) shipped on
3.1.0 yet volume rose ~55 → 122, confirming sample-and-drop does not fix it.

## Verification
- Build + `PalaceTests` green (incl. the new `UIAlertCACommitGuardTests` cases
  driving present-during-active-`transitionCoordinator` and the announcement
  present-during-dismiss shape, asserting no exception escapes).
- simdrive in-action: forced-401-at-cold-launch repro above — confirm the alert
  appears AFTER the transition settles with no crash across ~10 cold launches
  (`mcp__simdrive__crashes` clean). Required before merge per
  docs/bug-investigation-process.md.

**Not done / deferred:** the scroll-direction sub-variant (dormant); routing the
remaining non-launch raw-`present()` sites (reader-positions, problem-doc,
error-log exporter) onto the unified helper — lower-risk, not on the crashing
launch path, follow-up.
