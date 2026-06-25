---
name: pp-4652-epub-resume-drm-retry
created: 2026-06-24
author: claude-opus-4-8
---

## Summary

PP-4652 (Blocker, 3.2.0 build 482): an EPUB's last-read position is lost when the
app is force-quit and reopened — the book reopens to the cover. Reproduces ONLY
for DRM books (OverDrive / Palace Marketplace via A1QA); open-access EPUBs resume
fine. Root cause (confirmed by sim log `ReaderInitialLocationNavigator.swift:
Reader initial-location restore returned false; remaining at start (page 1).`):
#1084 made the post-paint gate the single restore authority and fired
`navigator.go(to:)` ONCE at `viewDidAppear`. A DRM/Adobe EPUB decrypts + loads
its WebContent more slowly, so Readium's location-mapping table is not populated
yet → the single `go(to:)` no-ops to `false` → #1084's "graceful page-1
degradation" lands on the cover. The synced server position then surfaces as the
"Sync Reading Position" dialog, and BOTH Stay and Move end on the cover because
finalizePresentation routes the (Move-updated) registry position back through the
same gate.

## Claims

- adds bounded retry to `ReaderInitialLocationNavigator.navigateIfReady()`: retries `navigator.go(to:)` up to `maxRestoreAttempts` (default 12) with `restoreRetryDelayNanos` (default 250ms) between tries, breaking on the first success
- adds init params `maxRestoreAttempts` + `restoreRetryDelayNanos` (defaulted) to `ReaderInitialLocationNavigator` for deterministic, fast tests
- records `restoreDidDegradeToStart` only after ALL attempts return false (genuinely unresolvable locator), preserving the observable graceful page-1 degradation
- updates `Reader initial-location restore returned false` log to include the attempt count
- adds test double field `goResultSequence` to `StubInitialLocationNavigator` (per-call results, falls back to `goResult`)
- adds test `testGate_goFalseThenTrue_retriesToSuccess_noDegradation` (PP-4652 regression: transient table-not-ready false→true must restore, not degrade)
- updates `testGate_goReturnsFalse_*` → `testGate_goPersistentlyFalse_retriesThenRecordsPage1Degradation` (asserts retries are exhausted before degrading)

## Anti-claims

- does NOT re-enable the navigator CONSTRUCTOR restore (`TPPEPUBViewController.navigatorConstructorInitialLocation` stays `nil`) — the post-paint gate remains the single restore authority, so a retried `go(to:)` cannot reintroduce the #1084 double-restore / WebContent teardown bounce
- does NOT change the SAVE path (`TPPLastReadPositionPoster`/`storeReadPosition`), `convertToLocator`, or the sync conflict rule in `TPPLastReadPositionSynchronizer` — convertToLocator succeeded in the repro (no HREF-resolution failure); the failure was the timing of the gate's go(to:)
- does NOT alter user-initiated post-load navigation (TOC select, bookmark select, page turns) — those fire after the WebContent is ready, so they are not subject to the not-ready window
- does NOT touch audiobooks, Android, or CPW

## Files in scope

- Palace/Reader2/UI/ReaderInitialLocationNavigator.swift
- PalaceTests/Reader2/TPPBaseReaderViewControllerInitialLocationTests.swift
