//
//  CarModeState.swift
//  Palace
//
//  Models for car mode state: book info, playback, and chapter data.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

// MARK: - CarModeBookInfo

/// Lightweight book metadata for car mode display.
public struct CarModeBookInfo: Equatable {
    public let identifier: String
    public let title: String
    public let author: String?
    public let coverImage: UIImage?
    public let totalDuration: TimeInterval?

    /// Progress through the entire book, 0.0 to 1.0.
    public var progress: Double

    public static func == (lhs: CarModeBookInfo, rhs: CarModeBookInfo) -> Bool {
        lhs.identifier == rhs.identifier
            && lhs.title == rhs.title
            && lhs.author == rhs.author
            && lhs.progress == rhs.progress
    }
}

// MARK: - CarModeChapterInfo

/// Chapter metadata for car mode display.
public struct CarModeChapterInfo: Equatable, Identifiable {
    public let index: Int
    public let title: String
    public let duration: TimeInterval
    public let isCurrent: Bool

    public var id: Int { index }

    /// Formatted duration string (e.g., "12:34").
    public var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
