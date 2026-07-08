---
name: carplay-cold-launch-gate-seam
created: 2026-06-12
author: claude-opus-4-8
tracking: regression-rebuild device-cells (HC-DEVICE-CELLS) — C-carplay cell
---

## Summary

The C-carplay regression cell (headless XCTest, per the CarPlay feasibility
verdict — CarPlay cannot be interactively driven on a sim) needs a real test of
the CarPlay cold-launch device-divergence gate. Today that gate is only
FLUFF-tested. This change extracts a pure decision seam so the behavior is
unit-testable, replaces the banned tautology test with a real round-trip
behavior test, and adds the scenario-1 statebleed round-trip test. Worktree
`feat/regression-rebuild-device-cells` off `origin/develop@51d21177c`.

## Claims

1. **Extract a pure cold-launch gate seam.** `CarPlayTemplateManager` decides
   whether to show the "open Palace on your phone" alert based on
   `SceneDelegate.hasMainSceneConnected` — when only CarPlay has connected
   (cold start from the car, main phone scene not connected), iOS limits
   background execution so playback won't work reliably, so the gate shows the
   alert instead of attempting playback. That decision is currently inline in
   the `private func handleBookSelection` (needs a `CPInterfaceController`, no
   public init → not headlessly testable). Extract it to a pure
   `static func shouldShowOpenAppAlert(mainSceneConnected: Bool) -> Bool` and
   wire the single call site to consult it. No behavior change — pure refactor
   that makes the device-divergence gate testable.

2. **Replace the fluff test with a real behavior test.**
   `testSceneDelegate_HasMainSceneConnected_Flag` is a banned tautology
   (`XCTAssertTrue(flag == true || flag == false)` + `XCTAssertNotNil(flag)`).
   Replace it 1:1 with round-trip behavior tests asserting both branches of the
   new seam (`mainSceneConnected: false → true (show alert)`,
   `mainSceneConnected: true → false (proceed)`).

3. **Add the scenario-1 statebleed round-trip test.** Prove `AppContainer
   ._resetForTesting()` (the #1072 fix) rebuilds fresh audiobook session
   statics, driven through the PRODUCTION seam
   (`AppContainer.production().audiobookSession / audiobookSessionPresenter /
   playbackBootstrapper`), not direct static writes: resolve the cached
   instances, call the reset, re-resolve, assert the instances are NOT identical
   (the reset released the prior — potentially CarPlay-presenter-polluted —
   instances). This is the canonical write→reset→re-enter round-trip.

## Anti-claims

- I am NOT changing the cold-launch gate's behavior — the seam returns exactly
  `!mainSceneConnected`, identical to the inline check it replaces.
- I am NOT touching the async auth/downloaded/offline gates below it, the
  playback path, or `SceneDelegate.hasMainSceneConnected` itself.
- I am NOT adding a test that requires a `CPInterfaceController` mock or asserts
  the private `handleBookSelection` directly (the seam is the testable unit; the
  single call site is verified by the diff).
- I am NOT modifying `AppContainer._resetForTesting()` — only testing its
  existing contract.

## Files in scope

- `Palace/CarPlay/CarPlayTemplateManager.swift` — add the pure seam + wire the
  one call site.
- `PalaceTests/CarPlay/CarPlayTests.swift` — replace the fluff test (2 seam
  tests) + add the statebleed round-trip test.
- (device-cells tooling under `scripts/` + `docs/regression-suite/` ship in the
  same PR but are covered by the workstream, not this intent.)
