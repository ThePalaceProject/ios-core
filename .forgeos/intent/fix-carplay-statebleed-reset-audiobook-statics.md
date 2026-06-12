---
name: fix-carplay-statebleed-reset-audiobook-statics
created: 2026-06-12
author: claude-opus-4-8 (w-carplay)
tracking: M0-reconverge — CarPlay state-bleed (last board-green blocker), initiative init_17bfe690
related_branches: ["fleet/w-carplay-carplay-statebleed (off develop)"]
---

## Summary

`CarPlayAudiobookBridgePresenterMigrationTests.testCarPlayBridge_dismissBookOnPhone_doesNotKillSession`
reds the CI board on any shuffle where an upstream test precedes it and leaves the
shared, never-reset `AppContainer._audiobookSessionPresenter` static in an
active-session state. The victim's precondition reads that shared static
(`presenter.hasActiveSession`); the bleed inverts it. On #1071's CI the victim
failed ALL iters-3 retries (the polluted static persists across retries in the same
process, so retry does not recover it) → deterministic-red-when-triggered, blocking
deterministic-green merges of WS-5 / WS-2.

`AppContainer._resetForTesting()` (the DEBUG-only, XCTest-gated test-boundary reset)
rebuilds `_cached` and now drains the AccountsManager crawl (w-stabilize's #1066
fix), but it does NOT reset the process-wide audiobook statics
(`_audiobookSession`, `_audiobookSessionPresenter`, `_playbackBootstrapper`) —
confirmed they are the only graph members it leaves intact (`_buildCachedAppContainer`
does not touch them).

Fix (option-C, structural, order-INDEPENDENT — mirrors the accepted crawl-drain
pattern): reset those three statics to `nil` in `_resetForTesting()` so each test
class boundary yields a fresh presenter (subscribed to a fresh session, the old
presenter's leaked subscription torn down on deinit). This neutralizes ANY polluter
that left the presenter active, without needing to name it — pinning a single
polluter in a randomized 201-class suite without the failing seed is the wrong tool
(15 candidate classes ruled out empirically). Approved by palace-pm.

## Claims

- Adds three static resets to `AppContainer._resetForTesting()` (inside the existing
  `#if DEBUG` + `XCTestConfigurationFilePath` gate → ZERO production/release impact):
  `_audiobookSession = nil`, `_audiobookSessionPresenter = nil`,
  `_playbackBootstrapper = nil`.
- Adds a deterministic red-first test
  `testResetForTesting_clearsLeakedActiveSessionFromSharedAudiobookPresenter` to
  `AppContainerResetTests`: pollutes the shared static presenter into an active
  session via the REAL publisher path (`production().audiobookSession.playbackStatePublisher.send(.playing)`,
  waited deterministically because delivery is async `.receive(on: DispatchQueue.main)`),
  calls `_resetForTesting()`, then asserts the next
  `production().audiobookSessionPresenter` resolution is a fresh presenter with
  `hasActiveSession == false`. RED before the fix (same static instance, still
  active); GREEN after. Tests the fix MECHANISM directly — not a behavioral model.

## Anti-claims (out of scope)

- Test-support only. The change lives entirely inside the `#if DEBUG` +
  XCTest-process-gated `_resetForTesting()` seam — not callable from production/release
  builds. No production runtime behavior changes.
- Does NOT name or fix a specific polluter test. The fix is structural and
  order-independent; it neutralizes any polluter at the class boundary. (The earlier
  "dispatch backlog" timing model was disproven by its own red-first and discarded.)
- Does NOT change `AudiobookSessionPresenter`, `AudiobookSessionManager`,
  `CarPlayAudiobookBridge`, or the CarPlay victim test.
- Does NOT change `testExecutionOrdering` (stays "random") or any scheme/test-plan
  config.

## Files in scope

- `Palace/AppInfrastructure/AppContainer.swift` (test-support `_resetForTesting()` only)
- `PalaceTests/AppInfrastructure/AppContainerResetTests.swift` (red-first test)
- `.forgeos/intent/fix-carplay-statebleed-reset-audiobook-statics.md` (this file)
