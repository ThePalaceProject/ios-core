//
//  SleepTimerOption.swift
//  Palace
//
//  Sleep timer presets for car mode audiobook playback.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - SleepTimerOption

/// Available sleep timer duration presets.
public enum SleepTimerOption: Equatable, Identifiable, CaseIterable {
    case minutes15
    case minutes30
    case minutes45
    case minutes60
    case endOfChapter

    public var id: String {
        switch self {
        case .minutes15: return "15min"
        case .minutes30: return "30min"
        case .minutes45: return "45min"
        case .minutes60: return "60min"
        case .endOfChapter: return "endOfChapter"
        }
    }

    /// Duration in seconds, or nil for end-of-chapter.
    public var duration: TimeInterval? {
        switch self {
        case .minutes15: return 15 * 60
        case .minutes30: return 30 * 60
        case .minutes45: return 45 * 60
        case .minutes60: return 60 * 60
        case .endOfChapter: return nil
        }
    }

    /// Human-readable label.
    public var displayName: String {
        switch self {
        case .minutes15: return "15 minutes"
        case .minutes30: return "30 minutes"
        case .minutes45: return "45 minutes"
        case .minutes60: return "60 minutes"
        case .endOfChapter: return "End of chapter"
        }
    }

    /// Short label for inline display.
    public var shortLabel: String {
        switch self {
        case .minutes15: return "15m"
        case .minutes30: return "30m"
        case .minutes45: return "45m"
        case .minutes60: return "60m"
        case .endOfChapter: return "Ch."
        }
    }
}

// MARK: - SleepTimerState

/// Represents the current state of the sleep timer.
public enum SleepTimerState: Equatable {
    case inactive
    case active(remaining: TimeInterval, option: SleepTimerOption)
    case endOfChapter

    public var isActive: Bool {
        switch self {
        case .inactive: return false
        case .active, .endOfChapter: return true
        }
    }

    /// Formatted remaining time string (e.g., "12:34").
    public var remainingFormatted: String? {
        switch self {
        case .inactive:
            return nil
        case .active(let remaining, _):
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            return String(format: "%d:%02d", minutes, seconds)
        case .endOfChapter:
            return "Ch."
        }
    }

    /// Button label: shows remaining time when active, "Sleep" when inactive.
    public var buttonLabel: String {
        switch self {
        case .inactive:
            return "Sleep"
        case .active(let remaining, _):
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            return String(format: "%d:%02d", minutes, seconds)
        case .endOfChapter:
            return "End Ch."
        }
    }
}
