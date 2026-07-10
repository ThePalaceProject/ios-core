//
//  PalaceMotion.swift
//  Palace
//
//  Shared motion + geometry constants for Palace UI polish (PP-4745).
//
//  A single source of truth for the app's standard animations and corner radii
//  so loading states, transitions, and pressable controls all feel the same.
//  Deployment target is iOS 17, so the modern spring presets are used directly.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Standard animations for Palace UI. Prefer these over inline `.easeInOut(...)`
/// literals so motion reads consistently across the app.
enum PalaceMotion {
    /// Default UI transition — the modern smooth spring. Use for most state changes.
    static let standard: Animation = .smooth

    /// Emphasized / interactive feedback (button press, selection). Snappier.
    static let emphasized: Animation = .snappy

    /// The audiobook player morph (expand ⇄ mini) + first-open settle. One
    /// smooth, slightly-eased spring shared by the cover `matchedGeometryEffect`,
    /// the controls, and the card corner-radius so every element settles on the
    /// SAME curve (no element lagging another, no overshoot jank). Response 0.42 /
    /// damping 0.9 = a premium, Libby/Audible-class settle. Springs retarget in
    /// flight, so this is interruptible if the user re-grabs mid-animation.
    static let playerMorph: Animation = .spring(response: 0.42, dampingFraction: 0.9)

    /// Gesture-release settle for the interactive pull-down (spring-BACK when the
    /// drag is released below the dismiss threshold). `interactiveSpring` blends
    /// cleanly with a re-grab, so grabbing the card again mid-settle feels fluid
    /// rather than fighting an in-flight animation.
    static let interactive: Animation = .interactiveSpring(response: 0.35, dampingFraction: 0.86, blendDuration: 0.25)

    /// Gentle, slightly longer fade — cover cross-fades, skeleton hand-offs.
    static let gentle: Animation = .smooth(duration: 0.4)

    /// Repeating highlight sweep for loading skeletons. Linear + never autoreverses
    /// so the shimmer band travels in one direction and loops seamlessly.
    static let shimmer: Animation = .linear(duration: 1.3).repeatForever(autoreverses: false)

    /// Resolves an animation against a reduce-motion flag: returns `nil`
    /// (i.e. no animation) when reduce motion is active, otherwise the animation.
    ///
    /// This is the pure decision used by the reactive reduce-motion view modifier
    /// and by `PalacePressableButtonStyle`, kept as a free static function so the
    /// gating logic is unit-testable without a SwiftUI host.
    static func resolved(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// The single global gate for CONTINUOUS, always-on animations (skeleton
    /// shimmer sweeps, cover-load pulses — anything that loops until content
    /// arrives). Such loops are suppressed when Reduce Motion is on (a11y) OR
    /// when Low Power Mode is on (battery / GPU). One seam so every continuous
    /// loop in the app makes the same decision.
    ///
    /// Pure so it is unit-testable without a SwiftUI host; the reactive views
    /// pass the live `@Environment(\.accessibilityReduceMotion)` and
    /// `ProcessInfo.processInfo.isLowPowerModeEnabled`.
    static func shouldAnimateContinuously(reduceMotion: Bool, lowPower: Bool) -> Bool {
        !reduceMotion && !lowPower
    }

    /// Horizontal offset (in points) of the shimmer highlight band for a given
    /// normalized `phase` in `[-1, 1]` over a content of `width` points.
    ///
    /// The band starts fully off the leading edge (`phase == -1` → `-width`),
    /// is centered at `phase == 0` (→ `0`), and ends fully off the trailing edge
    /// (`phase == 1` → `+width`). Because the offset is a function of the animated
    /// `phase`, a moving phase produces a visible sweep — this is exactly the
    /// visual property whose absence made the old shimmer render as a static wash.
    static func shimmerOffset(phase: CGFloat, width: CGFloat) -> CGFloat {
        phase * width
    }
}

/// Standard corner radii for Palace surfaces.
enum PalaceRadius {
    /// Cards, cover placeholders, larger surfaces.
    static let card: CGFloat = 12

    /// Controls, buttons, small chips.
    static let control: CGFloat = 8
}
