//
//  PlaybackSpeed.swift
//  Palace
//
//  Playback speed model with fine-grained options for car mode.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

// MARK: - PlaybackSpeed

/// Represents a playback speed with display metadata.
/// Supports 0.5x to 3.0x in 0.1x increments, with named presets.
public struct PlaybackSpeed: Equatable, Identifiable, Hashable {

    /// The speed multiplier (e.g., 1.0 = normal, 1.5 = 1.5x).
    public let rate: Double

    /// Optional named preset (e.g., "Normal", "Fast").
    public let presetName: String?

    public var id: Double { rate }

    /// Display string like "1.0x" or "1.5x (Fast)".
    public var displayLabel: String {
        let rateStr = rate.truncatingRemainder(dividingBy: 1.0) == 0
            ? String(format: "%.0fx", rate)
            : String(format: "%.1fx", rate)

        if let name = presetName {
            return "\(rateStr) (\(name))"
        }
        return rateStr
    }

    /// Compact label like "1x" or "1.5x" for buttons.
    public var compactLabel: String {
        rate.truncatingRemainder(dividingBy: 1.0) == 0
            ? String(format: "%.0fx", rate)
            : String(format: "%.1fx", rate)
    }

    // MARK: - Named Presets

    public static let slow = PlaybackSpeed(rate: 0.75, presetName: "Slow")
    public static let normal = PlaybackSpeed(rate: 1.0, presetName: "Normal")
    public static let fast = PlaybackSpeed(rate: 1.5, presetName: "Fast")
    public static let veryFast = PlaybackSpeed(rate: 2.0, presetName: "Very Fast")

    // MARK: - All Options

    /// All available speeds from 0.5x to 3.0x in 0.1x increments.
    public static let allOptions: [PlaybackSpeed] = {
        let presetMap: [Double: String] = [
            0.75: "Slow",
            1.0: "Normal",
            1.5: "Fast",
            2.0: "Very Fast",
        ]

        return stride(from: 0.5, through: 3.0, by: 0.1).map { rawRate in
            let rate = (rawRate * 10).rounded() / 10 // Avoid floating-point drift
            return PlaybackSpeed(rate: rate, presetName: presetMap[rate])
        }
    }()

    /// Quick-pick speeds shown by default in the picker.
    public static let quickPicks: [PlaybackSpeed] = [
        PlaybackSpeed(rate: 0.5, presetName: nil),
        .slow,
        .normal,
        PlaybackSpeed(rate: 1.25, presetName: nil),
        .fast,
        PlaybackSpeed(rate: 1.75, presetName: nil),
        .veryFast,
        PlaybackSpeed(rate: 2.5, presetName: nil),
        PlaybackSpeed(rate: 3.0, presetName: nil),
    ]

    // MARK: - Toolkit Conversion

    /// Converts to the toolkit's `PlaybackRate` type, using the closest match.
    public var toolkitRate: PlaybackRate {
        // The toolkit uses predefined rates; map to the closest one
        let rates: [(PlaybackRate, Double)] = [
            (.threeQuartersTime, 0.75),
            (.normalTime, 1.0),
            (.oneAndAQuarterTime, 1.25),
            (.oneAndAHalfTime, 1.5),
            (.doubleTime, 2.0),
        ]

        var closest = PlaybackRate.normalTime
        var smallestDiff = Double.infinity
        for (pbRate, value) in rates {
            let diff = abs(value - rate)
            if diff < smallestDiff {
                smallestDiff = diff
                closest = pbRate
            }
        }
        return closest
    }

    /// Creates a PlaybackSpeed from the toolkit's PlaybackRate.
    public static func from(toolkitRate: PlaybackRate) -> PlaybackSpeed {
        let rate = Double(PlaybackRate.convert(rate: toolkitRate))
        let presetMap: [Double: String] = [
            0.75: "Slow",
            1.0: "Normal",
            1.25: nil,
            1.5: "Fast",
            2.0: "Very Fast",
        ].compactMapValues { $0 }

        return PlaybackSpeed(rate: rate, presetName: presetMap[rate])
    }
}
