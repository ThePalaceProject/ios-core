//
//  PositionSnapshot.swift
//  PalaceReadingPosition
//
//  Wire-shaped DTO used on the position-write path. Distinct from
//  `ReadingPosition`, which is the persisted cross-format-mappable model.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A point-in-time snapshot of a reader's position, suitable for posting
/// to a server. Format-specific data is carried in `payload` as opaque
/// bytes so a single endpoint can accept all three formats.
public struct PositionSnapshot: Equatable, Sendable, Codable {
    /// The book this snapshot is for.
    public let bookID: String

    /// The content format the snapshot was recorded in.
    public let format: Format

    /// Format-specific serialized payload. EPUB callers post a Readium
    /// locator; audiobook callers post the toolkit's selectorValue; PDF
    /// callers post a JSON page descriptor. The writer is intentionally
    /// payload-agnostic.
    public let payload: Data

    /// When the position was captured by the client.
    public let timestamp: Date

    /// A device identifier used by the server for conflict-resolution
    /// at the call site. The writer doesn't inspect this.
    public let device: String

    public init(
        bookID: String,
        format: Format,
        payload: Data,
        timestamp: Date,
        device: String
    ) {
        self.bookID = bookID
        self.format = format
        self.payload = payload
        self.timestamp = timestamp
        self.device = device
    }

    /// The content format of a snapshot.
    public enum Format: String, Codable, Sendable {
        case audiobook
        case epubLocator
        case pdfPage
    }
}

// MARK: - Bridging to `ReadingPosition`

public extension PositionSnapshot {
    /// Construct a snapshot from a cross-format `ReadingPosition`.
    ///
    /// The position's format-specific fields are JSON-encoded into
    /// `payload`. Callers that own a format-specific locator string
    /// (Readium `Locator`, audiobook selector, PDF page number) should
    /// build a snapshot directly via `init(bookID:format:payload:...)`
    /// rather than round-tripping through `ReadingPosition`.
    init(from readingPosition: ReadingPosition) throws {
        let format: Format
        switch readingPosition.format {
        case .epub:
            format = .epubLocator
        case .audiobook:
            format = .audiobook
        case .pdf:
            format = .pdfPage
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(readingPosition)

        self.init(
            bookID: readingPosition.bookID,
            format: format,
            payload: data,
            timestamp: readingPosition.timestamp,
            device: readingPosition.deviceID
        )
    }

    /// Project the snapshot back to a `ReadingPosition`. Requires that
    /// the payload was JSON-encoded via `init(from:)`.
    func asReadingPosition() throws -> ReadingPosition {
        try JSONDecoder().decode(ReadingPosition.self, from: payload)
    }
}
