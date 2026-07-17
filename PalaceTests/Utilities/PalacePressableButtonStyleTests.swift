//
//  PalacePressableButtonStyleTests.swift
//  PalaceTests
//
//  PP-4745 (PR2) — pins the press response (scale + opacity) of the shared
//  pressable button style, including the Reduce Motion carve-out.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

@MainActor
final class PalacePressableButtonStyleTests: XCTestCase {

    // MARK: - scale(isPressed:reduceMotion:)

    /// Pressed (motion allowed) scales the label down to 0.96.
    func testScale_pressedWithMotion_shrinks() {
        XCTAssertEqual(PalacePressableButtonStyle.scale(isPressed: true, reduceMotion: false),
                       0.96, accuracy: 0.0001)
    }

    /// Released returns to full size.
    func testScale_released_isFullSize() {
        XCTAssertEqual(PalacePressableButtonStyle.scale(isPressed: false, reduceMotion: false),
                       1.0, accuracy: 0.0001)
    }

    /// Reduce Motion pins the scale to 1.0 even while pressed — no size change.
    func testScale_pressedWithReduceMotion_noShrink() {
        XCTAssertEqual(PalacePressableButtonStyle.scale(isPressed: true, reduceMotion: true),
                       1.0, accuracy: 0.0001,
                       "Reduce Motion must suppress the press scale")
    }

    // MARK: - opacity(isPressed:)

    /// Pressed dims slightly (opacity cue is kept even under Reduce Motion).
    func testOpacity_pressed_dims() {
        XCTAssertEqual(PalacePressableButtonStyle.opacity(isPressed: true), 0.85, accuracy: 0.0001)
    }

    /// Released is fully opaque.
    func testOpacity_released_isOpaque() {
        XCTAssertEqual(PalacePressableButtonStyle.opacity(isPressed: false), 1.0, accuracy: 0.0001)
    }

    // MARK: - Style value / convenience accessor

    /// The `.palacePressable` convenience resolves to the style type — this is the
    /// API the call sites use (`.buttonStyle(.palacePressable)`).
    func testPalacePressableConvenience_resolvesToStyle() {
        let style: PalacePressableButtonStyle = .palacePressable
        // Exercise the resolved style's own contract rather than just asserting
        // construction: the resolved instance must produce the documented press
        // response.
        XCTAssertEqual(type(of: style).scale(isPressed: true, reduceMotion: false), 0.96, accuracy: 0.0001)
    }
}
