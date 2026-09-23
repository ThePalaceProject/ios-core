---
name: pp4533-block-by-block-navigation
created: 2026-06-23
author: claude-opus-4-8
branch: feature/PP-4533-block-navigation
priority: PP-4533 / Epic PP-833 EPUB Accessibility (DAISY reading-810)
---

# Intent: block-by-block screen-reader navigation in the iOS reader

## Context

Palace iOS fails DAISY reading-810 ("Block Navigation"): the Reader2 (Readium 3.x)
reader gives VoiceOver users no way to move through content one logical block at a
time (paragraph, heading, list item, quote, definition term/description,
preformatted text, figure caption). Block navigation must operate on the rendered
spine HTML — the logical blocks live INLINE in the chapter DOM, NOT in the Readium
manifest — so they are surfaced to VoiceOver by marking the rendered WKWebView DOM
(see TPPEPUBViewController), not by parsing `publication`. This mirrors the
just-built PP-4531 footnote pattern.

Grounded surface:
- `TPPEPUBViewController` already injects JS on chapter render via
  `epubNavigator.evaluateJavaScript(...)` and, in VoiceOver mode, sets
  `navigator.view.isAccessibilityElement = false` so VoiceOver traverses the
  WKWebView DOM directly.
- `AccessibilityPreferences.customRotorActionsEnabled` (default on) is the
  established gate for custom rotor actions.

## Claims

- New `TPPReaderBlockNavigation` (pure, Foundation-only): owns the block-element
  selector (`p, h1..h6, li, blockquote, figcaption, dd, dt, pre, [role="heading"],
  [role="listitem"]`), a unit-testable `isBlockTag(_:)` classifier, an
  `annotationJavaScript()` that marks the OUTERMOST matching blocks
  (`tabindex="-1"` + `data-pp-block="1"`, nested blocks skipped) and returns the
  marked count, and a `nextBlockJavaScript(forward:)` focus-walk. No UIKit/Readium
  state; unit-tested in isolation.
- `annotationJavaScript()` / `nextBlockJavaScript(forward:)` are thin DOM mirrors
  of the tested selector spec — no duplication of the block-classification rule.
- Wired into `TPPEPUBViewController`: `annotateBlocksForVoiceOver()` runs on every
  chapter render (alongside the chapter-change VoiceOver guard), and a
  `makeBlockRotor()` UIAccessibilityCustomRotor ("Blocks") walks the marked blocks
  forward/back, gated on `customRotorActionsEnabled`. Additive and idempotent;
  does not alter reading position.

## Verification

- Unit: `harness test -- -only-testing:PalaceTests/TPPReaderBlockNavigationTests` —
  all pass (selector/classifier + marking-JS + focus-walk-JS shape).
- Runtime (pending): device/host-AX VoiceOver pass on the DAISY reading-810
  fixture — open the "Blocks" rotor, swipe up/down to step block-by-block forward
  and back. The marked-count is emitted via `Log.info` ("PP-4533 block-nav marked
  N blocks for VoiceOver") since the injected DOM marks live in the Readium
  WKWebView web-AX, which host-AX / simdrive cannot inspect on the simulator.

## Files in scope

- `Palace/Reader2/BusinessLogic/TPPReaderBlockNavigation.swift` (new) — pure block selector + classifier + marking/focus-walk JS.
- `Palace/Reader2/UI/TPPEPUBViewController.swift` — `annotateBlocksForVoiceOver()` + call in `didChangeLocation`, `makeBlockRotor()` + rotor attachment in `configureAccessibilityActions()`.
- `Palace/Utilities/Localization/Strings.swift` — `blockRotorTitle` ("Blocks").
- `PalaceTests/Reader2/TPPReaderBlockNavigationTests.swift` (new) — unit tests.
- `Palace.xcodeproj/project.pbxproj` — register the two new files (Palace, Palace-noDRM, PalaceTests).

## Anti-claims

- Does NOT change reading position — the rotor only moves VoiceOver focus among
  existing block elements; it never calls `navigator.go(...)`.
- Does NOT parse blocks from the Readium manifest/`publication` (they are not
  there) — detection is DOM-only via injected JS.
- Does NOT add a visible control or settings UI for sighted users — this is
  screen-reader behavior only, reusing the existing `customRotorActionsEnabled`
  preference.
- Does NOT claim the runtime VoiceOver behavior is verified — only the pure
  selector/classifier and JS shape are unit-tested; the marked-count is via
  `os_log` and the device/host-AX pass is explicitly pending.
