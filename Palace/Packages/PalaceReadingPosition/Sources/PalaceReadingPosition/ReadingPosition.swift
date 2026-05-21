//
//  ReadingPosition.swift
//  PalaceReadingPosition
//
//  Unified reading position across EPUB, audiobook, and PDF formats.
//  Migrated from Palace/Platform/ on 2026-05-21 (Swarm 2, Deviation 4).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The content format associated with a `ReadingPosition` or cross-format
/// sync record.
///
/// Note: `Palace/Stats/Models/ReadingSession.swift` declares an
/// `internal` enum named `ReadingFormat` with the same cases. That is
/// intentional duplication during the post-Swarm-2 cutover — stats are
/// not consumers of `PalaceReadingPosition`. The two enums will be
/// reconciled in a future cleanup pass.
public enum ReadingFormat: String, Codable, Sendable, CaseIterable {
    case epub
    case audiobook
    case pdf
}

/// A unified reading position that can represent a location in any
/// supported format.
public struct ReadingPosition: Codable, Equatable, Sendable {

    // MARK: - Common Properties

    /// The book identifier this position belongs to.
    public let bookID: String

    /// The content format this position was recorded in.
    public let format: ReadingFormat

    /// When this position was recorded.
    public let timestamp: Date

    /// The device that recorded this position.
    public let deviceID: String

    // MARK: - EPUB Properties

    /// Zero-based chapter index for EPUB.
    public var chapterIndex: Int?

    /// Progress within the current chapter (0.0 to 1.0) for EPUB.
    public var chapterProgress: Double?

    /// Canonical Fragment Identifier for precise EPUB location.
    public var cfi: String?

    // MARK: - Audiobook Properties

    /// Zero-based chapter index for audiobook.
    public var audiobookChapterIndex: Int?

    /// Time offset in seconds within the audiobook chapter.
    public var audiobookTimeOffset: TimeInterval?

    // MARK: - PDF Properties

    /// One-based page number for PDF.
    public var pdfPageNumber: Int?

    // MARK: - Overall Progress

    /// Overall progress through the entire book (0.0 to 1.0), if known.
    public var overallProgress: Double?

    // MARK: - Designated init

    public init(
        bookID: String,
        format: ReadingFormat,
        timestamp: Date,
        deviceID: String,
        chapterIndex: Int? = nil,
        chapterProgress: Double? = nil,
        cfi: String? = nil,
        audiobookChapterIndex: Int? = nil,
        audiobookTimeOffset: TimeInterval? = nil,
        pdfPageNumber: Int? = nil,
        overallProgress: Double? = nil
    ) {
        self.bookID = bookID
        self.format = format
        self.timestamp = timestamp
        self.deviceID = deviceID
        self.chapterIndex = chapterIndex
        self.chapterProgress = chapterProgress
        self.cfi = cfi
        self.audiobookChapterIndex = audiobookChapterIndex
        self.audiobookTimeOffset = audiobookTimeOffset
        self.pdfPageNumber = pdfPageNumber
        self.overallProgress = overallProgress
    }

    // MARK: - Convenience factories

    public static func epub(
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

    public static func audiobook(
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

    public static func pdf(
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

    public static var currentDeviceID: String {
        if let existing = UserDefaults.standard.string(forKey: "Palace.Platform.deviceID") {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: "Palace.Platform.deviceID")
        return newID
    }

    // MARK: - Display

    /// A human-readable description of this position.
    public var displayDescription: String {
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
