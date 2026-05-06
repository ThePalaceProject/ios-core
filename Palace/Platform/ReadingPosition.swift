//
//  ReadingPosition.swift
//  Palace
//
//  Unified reading position across EPUB, audiobook, and PDF formats.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A unified reading position that can represent a location in any supported format.
struct ReadingPosition: Codable, Equatable, Sendable {

    // MARK: - Common Properties

    /// The book identifier this position belongs to.
    let bookID: String

    /// The content format this position was recorded in.
    let format: ReadingFormat

    /// When this position was recorded.
    let timestamp: Date

    /// The device that recorded this position.
    let deviceID: String

    // MARK: - EPUB Properties

    /// Zero-based chapter index for EPUB.
    var chapterIndex: Int?

    /// Progress within the current chapter (0.0 to 1.0) for EPUB.
    var chapterProgress: Double?

    /// Canonical Fragment Identifier for precise EPUB location.
    var cfi: String?

    // MARK: - Audiobook Properties

    /// Zero-based chapter index for audiobook.
    var audiobookChapterIndex: Int?

    /// Time offset in seconds within the audiobook chapter.
    var audiobookTimeOffset: TimeInterval?

    // MARK: - PDF Properties

    /// One-based page number for PDF.
    var pdfPageNumber: Int?

    // MARK: - Overall Progress

    /// Overall progress through the entire book (0.0 to 1.0), if known.
    var overallProgress: Double?

    // MARK: - Initialization

    static func epub(
        bookID: String,
        chapterIndex: Int,
        chapterProgress: Double,
        cfi: String? = nil,
        overallProgress: Double? = nil,
        deviceID: String = Self.currentDeviceID
    ) -> ReadingPosition {
        ReadingPosition(
            bookID: bookID,
            format: .epub,
            timestamp: Date(),
            deviceID: deviceID,
            chapterIndex: chapterIndex,
            chapterProgress: min(max(chapterProgress, 0), 1),
            cfi: cfi,
            overallProgress: overallProgress
        )
    }

    static func audiobook(
        bookID: String,
        chapterIndex: Int,
        timeOffset: TimeInterval,
        overallProgress: Double? = nil,
        deviceID: String = Self.currentDeviceID
    ) -> ReadingPosition {
        ReadingPosition(
            bookID: bookID,
            format: .audiobook,
            timestamp: Date(),
            deviceID: deviceID,
            audiobookChapterIndex: chapterIndex,
            audiobookTimeOffset: max(timeOffset, 0),
            overallProgress: overallProgress
        )
    }

    static func pdf(
        bookID: String,
        pageNumber: Int,
        overallProgress: Double? = nil,
        deviceID: String = Self.currentDeviceID
    ) -> ReadingPosition {
        ReadingPosition(
            bookID: bookID,
            format: .pdf,
            timestamp: Date(),
            deviceID: deviceID,
            pdfPageNumber: max(pageNumber, 1),
            overallProgress: overallProgress
        )
    }

    // MARK: - Device ID

    static var currentDeviceID: String {
        if let existing = UserDefaults.standard.string(forKey: "Palace.Platform.deviceID") {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: "Palace.Platform.deviceID")
        return newID
    }

    // MARK: - Display

    /// A human-readable description of this position.
    var displayDescription: String {
        switch format {
        case .epub:
            if let chapter = chapterIndex, let progress = chapterProgress {
                let pct = Int(progress * 100)
                return "Chapter \(chapter + 1), \(pct)% through"
            }
            return "EPUB position"
        case .audiobook:
            if let chapter = audiobookChapterIndex, let offset = audiobookTimeOffset {
                let minutes = Int(offset) / 60
                let seconds = Int(offset) % 60
                return "Chapter \(chapter + 1), \(minutes):\(String(format: "%02d", seconds))"
            }
            return "Audiobook position"
        case .pdf:
            if let page = pdfPageNumber {
                return "Page \(page)"
            }
            return "PDF position"
        }
    }
}
