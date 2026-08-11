---
name: pp-4911-full-audiobook-player-icons
created: 2026-08-11
author: claude-opus-4-8
---

# Intent: PP-4911 — full audiobook player icons → Alissa's revised set

**Routed:** /rigorous-fix (critical-path audiobook UI, single view) · behind the
existing `in_app_playback_nav` flag. Visual-only change to the in-app morphing
player's controls.

## Claims (what the diff WILL do)
- Replace the audiobook player's control glyphs with Alissa's revised icon set,
  **vectorized from her PNG exports** (traced to clean SVGs) and added as
  template imagesets in `PalaceConfig/Images.xcassets` (`ABPlayer*`) — SF Symbols
  did not match her shapes. Template rendering tints them by appearance.
- Full (expanded) player — circular buttons per her Figma: skip-back /
  skip-forward glyphs (interval value overlaid INSIDE the arrow) on light-gray
  circles; play/pause on an emphasized solid circle with an inverted glyph (black
  circle + white glyph in light; white + dark in dark); close is her glyph.
- Full player bottom row: speed stays a text pill; AirPlay, sleep, bookmark are
  gray circular buttons, sized up ~1.4× to match the Figma. AirPlay shows her
  "source" glyph over an invisible `AVRoutePickerView` that still handles the
  route-selection tap (behavior unchanged). Sleep expands to a capsule with a
  countdown when active.
- Mini player — the SAME circular treatment, smaller: gray circles for close /
  skip (value inside), black-invert circle for play/pause. (Folds the mini
  glyph swap in alongside the full player at Maurice's direction.)
- A generated `pause` glyph (Alissa shipped only `play`) matched to her weight.
- Colors are semantic (`secondarySystemFill`, `Color.primary` / `systemBackground`)
  so light/dark adapt automatically.

## Anti-claims (what it will NOT do)
- No change to any control's BEHAVIOR, action, position/order, or VoiceOver label
  (visual-only). AirPlay still opens the system route picker; its control is one
  VoiceOver element labelled "AirPlay" (`.accessibilityElement(children: .ignore)`).
- One acknowledged nuance: the AirPlay glyph no longer tints to show the ACTIVE
  routing state (it is Alissa's static custom glyph). Matching her design on
  purpose; a distinct active-AirPlay state is deferred to the pre-GA icon pass.
- Does NOT touch the legacy toolkit `AudiobookPlayerView`.
- Does NOT change the `in_app_playback_nav` flag, ship/GA anything, or alter
  skip-interval behavior.
- Leaves the top-right chapters/TOC `list.bullet` as-is (Alissa did not ship a
  TOC glyph).
- No new network, DRM, persistence, or Android surface.

## Files in scope
- Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift (transportRow,
  bottomControls, skip helpers, mini controls, `AirPlayRoutePicker` tint param).
- PalaceConfig/Images.xcassets/ABPlayer*.imageset (new template vector assets).

## Verification
- Visual: build + drive both players on device in BOTH light and dark — confirm
  the circular buttons, play black↔white inversion, skip value inside the arrow,
  Alissa's AirPlay/sleep/bookmark glyphs, and the larger bottom controls.
  Confirmed on device (iPhone 17 Pro Max) across light/dark.
- No new unit tests: the change is pure presentation (template images + shapes +
  semantic colors) with no extractable logic; the existing `ControlMetrics`
  tests still pin sizing. Assert-a-color tests would be banned coverage fluff.
