//
//  PalacePressableButtonStyle.swift
//  Palace
//
//  Shared button style that adds a subtle press response (scale + opacity) to
//  high-traffic tap targets (cover cards, shelf cells). Reduce-motion aware:
//  no scale when Reduce Motion is on. Uses `PalaceMotion` for the press spring.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// A `ButtonStyle` that keeps the plain (untinted) look of `.plain` while adding a
/// gentle press response: the label scales down slightly and dims while pressed.
/// Respects Reduce Motion — the scale collapses to `1.0` (no movement) when the
/// user has Reduce Motion enabled, though the opacity cue remains.
struct PalacePressableButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        // Nest an inner view so the style can read the live accessibility
        // environment reactively (a raw `makeBody` can't hold `@Environment`).
        PressableLabel(configuration: configuration)
    }

    private struct PressableLabel: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(PalacePressableButtonStyle.scale(isPressed: configuration.isPressed,
                                                              reduceMotion: reduceMotion))
                .opacity(PalacePressableButtonStyle.opacity(isPressed: configuration.isPressed))
                .animation(PalaceMotion.resolved(PalaceMotion.emphasized, reduceMotion: reduceMotion),
                           value: configuration.isPressed)
        }
    }

    // MARK: - Pure, testable press response

    /// Scale factor for the pressed / released states. Reduce Motion pins the
    /// scale to `1.0` so there is no size change.
    static func scale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 1.0 }
        return isPressed ? 0.96 : 1.0
    }

    /// Opacity for the pressed / released states. A subtle dim on press that is
    /// kept even under Reduce Motion (opacity is not motion).
    static func opacity(isPressed: Bool) -> Double {
        isPressed ? 0.85 : 1.0
    }
}

extension ButtonStyle where Self == PalacePressableButtonStyle {
    /// The shared Palace pressable style: `.buttonStyle(.palacePressable)`.
    static var palacePressable: PalacePressableButtonStyle { PalacePressableButtonStyle() }
}
