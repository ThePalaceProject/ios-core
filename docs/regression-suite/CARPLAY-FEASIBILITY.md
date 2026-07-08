# CarPlay regression-cell feasibility + design (C-carplay)

> Verdict from the regression-rebuild device-cells workstream (HC-DEVICE-CELLS),
> 2026-06-12. Decides how the CarPlay surface is covered in the cross-device
> matrix. **Bottom line: CarPlay cannot be interactively driven on a simulator;
> C-carplay is a headless-XCTest cell, not a simdrive-journey cell.**

## 1. The question

Can simdrive (or XCUITest) drive the Simulator's CarPlay external display
(Simulator.app → I/O → External Displays → CarPlay) so the regression campaign
can fan area-workers across CarPlay like it does the iPhone/iPad cells?

## 2. Verdict — by capability (each backed by what was actually run)

| Capability | Feasible? | Evidence |
|---|---|---|
| **Activate** the CarPlay external display | Only via Simulator.app **private API / GUI menu** — NOT `simctl` | `xcrun simctl help` has no carplay/external-display subcommand. `strings Simulator` exposes `enableCarPlay:error:`, `-[DeviceCoordinator configureExternalDisplay:]`, `setExternalDisplayMode:forDevice:`, `carplayScreenWithSize:scale:`, and the log "Enabled CarPlay UI. CarPlay should be running." The `SimulatorExternalDisplay` default (=2114 globally in DevicePreferences) persists the mode but isn't a clean per-device on-switch. |
| **Observe / screenshot** the CarPlay display | Yes, but **gated on activation** | `xcrun simctl io <udid> screenshot --display external` exists; run with no CarPlay active → `Timeout waiting for screen surfaces`. So visual capture only works *after* the fragile activation above. |
| **Drive / tap** the CarPlay UI | **No** (the real blocker) | `simctl io` = screenshot/record/enumerate only, no touch injection. simdrive HID targets the device **internal-display** coordinate space, not the external CarPlay `NSWindow`/scene. XCUITest has **no public CarPlay API** — `XCUIApplication` attaches to the main foreground scene; the `CPTemplateApplicationScene` head-unit is not queryable/tappable. You cannot script "tap a book in the CarPlay list → assert playback." |
| **Headless logic testing** of CarPlay templates/scene | **Yes — and already present** | `PalaceTests/CarPlay/` drives `CarPlayAudiobookBridge`, `CarPlayTemplateManager`/`Builder`, `CarPlayImageProvider`, and the scene-delegate readiness gate via `CPInterfaceController` with no sim CarPlay window. This is where the automated regression signal lives. |

This **upgrades** the original design doc's blanket "CarPlay stays manual/XCTest"
(REGRESSION-REBUILD-DESIGN.md §4.2): there is a concrete, already-existing
headless automation surface that is the cell's primary signal.

## 3. C-carplay cell design (v1 = headless-only)

- **PRIMARY (automated, CI):** the headless `PalaceTests/CarPlay` XCTest suite,
  run on the C-iphone-26 base sim and converted to findings.
  - Runner: `scripts/regression-carplay-cell.sh`
  - Failures → findings: `scripts/regression_xcresult_findings.py` (own shard
    `<run>/findings/C-carplay__carplay.csv`, pinned schema; a crashed test →
    `classification=crash, severity=blocker`, an assertion failure → `other/major`).
  - The cell does **not** fan out simdrive area-workers.
- **SECONDARY (DEFERRED — fast-follow):** automated *visual capture* of an
  activated CarPlay display for the visual-diff gallery. See §4.
- **TERTIARY (manual):** true head-unit tap-through that no automated path
  covers. See §5.

## 4. DEFERRED — SECONDARY visual-capture PoC (fast-follow, not built)

Not built for v1 (fragile, GUI/private-API-coupled, low ROI). If the visual-diff
stage later wants CarPlay frames, the path is:

1. **Activate** the CarPlay external display on a booted sim — either
   - AppleScript UI-script the menu *I/O → External Displays → CarPlay*
     (needs Accessibility permission + the device window focused), or
   - a tiny CoreSimulator/Simulator helper calling the private
     `setExternalDisplayMode:forDevice:` / `enableCarPlay:` path.
2. **Capture** with `xcrun simctl io <udid> screenshot --display external`
   (the external framebuffer enumerates as `Display class: 1` once active).
3. Feed the PNG into the masked-SSIM visual-diff stage as a CarPlay baseline.

Treat as **best-effort, non-gating** — the activation step is the fragile part.

## 5. TERTIARY — manual CarPlay interaction checklist (honest gap)

Behaviors no sim/XCUITest path can drive — run on a real head unit or the
Simulator CarPlay window before a release:

- [ ] CarPlay connects → Palace library tab appears with downloaded audiobooks.
- [ ] Tap a downloaded audiobook → Now Playing dash UI appears, playback starts.
- [ ] Cold-launch from CarPlay (phone app not foregrounded) → the **"open Palace
      on your phone" alert** shows instead of a silent failure (the
      `hasMainSceneConnected==false` gate — see §6).
- [ ] Tap a NOT-downloaded book → "download required" alert.
- [ ] Tap a book on a library that requires auth, not signed in → "auth
      required" alert (not a bare 401).
- [ ] Now-Playing transport controls (play/pause, skip ±, chapter list) and the
      lock-screen / Siri controls reflect playback state.
- [ ] Disconnect/reconnect CarPlay mid-playback → state restored, no crash.

## 6. Known test gap (tracked) — the cold-launch open-app gate

`CarPlayTemplateManager.handleBookSelection` shows the open-app alert when
`SceneDelegate.hasMainSceneConnected == false` (CarPlay-only cold start). This
**device-divergence behavior is not headlessly unit-tested** — the existing
`testSceneDelegate_HasMainSceneConnected_Flag` only asserts the flag is a Bool
(a tautology), and the real decision is `private` + needs a `CPInterfaceController`
(no public init) + reads a static flag. Closing it cleanly needs a small
production seam extraction (a pure `shouldShowOpenAppAlert(mainSceneConnected:)`
decision) so the behavior — not the flag — can be asserted, plus a round-trip
test (`false → alert`, `true → proceeds`). Tracked as a C-carplay fast-follow;
until then it is a §5 manual checklist item.
