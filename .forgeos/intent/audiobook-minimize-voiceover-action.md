---
name: audiobook-minimize-voiceover-action
created: 2026-09-23
author: claude-opus-5
---

## Summary

A patron reported not realising the full audiobook player could be pulled down
to minimize. Investigating the discoverability complaint surfaced a harder
defect underneath it: minimizing is a DragGesture, which VoiceOver and Switch
Control cannot perform, and the grab handle carried accessibilityHidden(true).
For those patrons the only exit from the full player was the close control,
which calls closePlayer() and ends the session — so "keep listening while I
browse" was not merely undiscoverable, it was unreachable.

The asymmetry is visible in the existing strings: the mini-player already
exposes the opposite direction (expandPlayerHint, restoreAudiobookPlayerHint),
while the collapse direction had no string at all.

This change gives the pull-down an activatable equivalent. The VISUAL
discoverability half is deliberately NOT here — it goes to design via PP-4498,
which already carries an acceptance criterion for the first-use treatment.

## Claims

- removes accessibilityHidden(true) from the grabber in Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift
- makes the grabber an accessibility element with a label, a hint, the isButton trait, and an accessibilityAction that calls presenter.minimize()
- adds minimizePlayer and minimizePlayerHint to Strings.Generic in Palace/Utilities/Localization/Strings.swift
- adds a source-sentinel test asserting the grabber exposes an activatable minimize, following the pattern CatalogLaneRowViewAccessibilityTests already uses because SwiftUI accessibility trees are not materialized in a unit-test process without VoiceOver running
- adds a test asserting the minimize and close labels are not interchangeable, since one keeps playback alive and the other ends it
- adds a declarationBody test helper that strips whole-line comments before matching, so the sentinel cannot pass by reading its own documentation

## Anti-claims

- does NOT add any visible minimize control; the bottom-of-screen affordance is PP-4498 design work and is explicitly deferred
- does NOT change minimize() or closePlayer() behaviour, or any state transition in AudiobookSessionPresenter
- does NOT change the drag gesture, its threshold, the rubber-band curve, or the cover-art drag zone
- does NOT alter the visual appearance of the grabber (fill, opacity, or dimensions are untouched)
- does NOT touch the ios-audiobooktoolkit submodule or its recorded pin
- does NOT address the RemoteFeatureFlagsTests.testInAppPlaybackNav_noOverride_defaultsOff hermeticity defect found while verifying this change; that is a separate pre-existing issue to be filed on its own

## Files in scope

- Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift
- Palace/Utilities/Localization/Strings.swift
- PalaceTests/AppInfrastructure/AudiobookMorphingPlayerViewTests.swift
- .forgeos/intent/audiobook-minimize-voiceover-action.md (NEW)
