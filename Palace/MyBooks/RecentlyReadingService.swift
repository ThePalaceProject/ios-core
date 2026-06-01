//
//  RecentlyReadingService.swift
//  Palace
//
//  P1/P2 data layer for the "Continue Reading" row on the Catalog tab.
//  Returns a deterministic ordered list of in-progress EPUB / PDF books.
//  Audiobooks are NOT included here — they flow through the separate
//  "Continue Listening" surface driven by AudiobookSessionManaging.
//
//  See docs/architecture/in-app-navigation-during-playback.md §6.3 + §8.
//  See .forgeos/swarms/swarm_0b7616e7/contracts/A-RecentlyReading-ActiveSessions.md.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - ContinueReadingItem

/// A single entry in the "Continue Reading" row. Stable identity is the book
/// identifier so SwiftUI Lists can diff cleanly across refreshes.
struct ContinueReadingItem: Identifiable, Equatable {
    var id: String { bookId }
    let bookId: String
    let book: TPPBook
    /// `.epub` or `.pdf` — never `.audiobook`. Audiobooks go to
    /// `ContinueListeningItem` via `ActiveSessionsViewModel`.
    let contentType: TPPBookContentType
    /// Best-effort last-read timestamp. Parsed from the renderer-specific
    /// JSON inside `TPPBookLocation.locationString` when available
    /// (`timeStamp` ISO8601 key), otherwise falls back to `book.updated`.
    /// Never nil because the caller relies on it for the sort order.
    let lastReadAt: Date
    /// Optional progress fraction in [0.0, 1.0]. Nil when the renderer's
    /// location JSON doesn't expose one (older PDF locations, mismatched
    /// renderers). Module B renders a fallback CTA when nil.
    let progressFraction: Double?
    /// Optional human-readable progress label (e.g. "Chapter 3" or "Page 42").
    /// Nil when not derivable from the location JSON.
    let progressLabel: String?

    /// Identity for SwiftUI diffing is `bookId`. Two items refer to the
    /// "same" Continue Reading entry iff they describe the same book.
    /// (Display fields like `lastReadAt` / `progressLabel` legitimately
    /// change for the same item across refreshes; comparing them here
    /// would force the row to re-create even on a benign update.)
    static func == (lhs: ContinueReadingItem, rhs: ContinueReadingItem) -> Bool {
        lhs.bookId == rhs.bookId
    }
}

// MARK: - RecentlyReadingService

/// Returns "Continue Reading" candidates ordered by last-read timestamp
/// descending. Excludes samples, audiobooks, and books with no saved
/// location. Caller (Module B) is responsible for taking `prefix(limit)` —
/// the service always returns the full ordered set so the caller can
/// dynamically pick the row width.
@MainActor
protocol RecentlyReadingService {
    func recentlyReading() -> [ContinueReadingItem]
}

// MARK: - DefaultRecentlyReadingService

/// Concrete service. Pure function of `bookRegistry.myBooks` +
/// `bookRegistry.location(forIdentifier:)`. No external I/O. No
/// singleton reads — all collaborators arrive via the initializer.
@MainActor
final class DefaultRecentlyReadingService: RecentlyReadingService {

    private let bookRegistry: TPPBookRegistryProvider
    /// Clock injection lets tests pin "now" without freezing wall time.
    /// The default (`Date.init`) makes production callers ergonomic.
    private let clock: () -> Date

    init(bookRegistry: TPPBookRegistryProvider,
         clock: @escaping () -> Date = Date.init) {
        self.bookRegistry = bookRegistry
        self.clock = clock
    }

    func recentlyReading() -> [ContinueReadingItem] {
        let now = clock()
        let candidates: [ContinueReadingItem] = bookRegistry.myBooks.compactMap { book in
            // Acquisition gate — anything we can't read (no acquisition,
            // audiobook, unsupported MIME) is filtered before the sample
            // check, so the sample predicate only runs on books that
            // would otherwise render.
            guard let acquisition = book.defaultAcquisition else { return nil }
            let contentType = book.defaultBookContentType
            guard contentType == .epub || contentType == .pdf else { return nil }
            // Sample / preview gate — sample books are previews, not
            // borrowed reading sessions, and don't belong on the row.
            if acquisition.relation == .sample || acquisition.relation == .preview {
                return nil
            }
            // No saved location → no Continue Reading entry; user hasn't
            // opened this book yet.
            guard let location = bookRegistry.location(forIdentifier: book.identifier) else {
                return nil
            }
            let parsed = parseLocation(location, fallbackUpdated: book.updated, now: now)
            return ContinueReadingItem(
                bookId: book.identifier,
                book: book,
                contentType: contentType,
                lastReadAt: parsed.lastReadAt,
                progressFraction: parsed.progressFraction,
                progressLabel: parsed.progressLabel
            )
        }

        // Sort by lastReadAt descending; break ties by book identifier
        // ascending so the order is deterministic when two books share a
        // timestamp (typical for fallback paths that use `book.updated`).
        return candidates.sorted { lhs, rhs in
            if lhs.lastReadAt != rhs.lastReadAt {
                return lhs.lastReadAt > rhs.lastReadAt
            }
            return lhs.bookId < rhs.bookId
        }
    }

    // MARK: - Internal helpers

    /// Parses a renderer-specific location JSON. The audiobook bookmark
    /// shape embeds `timeStamp` as an ISO8601 string — we look for that.
    /// EPUB Readium 3.x and PDF locations do NOT embed a timestamp today;
    /// for those we fall back to `book.updated` (the OPDS feed's
    /// last-updated date) which is deterministic and present on every book.
    /// `now` is captured for future extensions (e.g. clamping nonsense
    /// timestamps); current implementation does not use it.
    private func parseLocation(
        _ location: TPPBookLocation,
        fallbackUpdated: Date,
        now: Date
    ) -> ParsedLocation {
        let dict = location.locationStringDictionary()

        let parsedTimestamp: Date? = (dict?["timeStamp"] as? String)
            .flatMap { Self.timestampFormatter.date(from: $0) }
        let progress: Double? = (dict?["progressWithinBook"] as? Double)
            .flatMap { (0.0...1.0).contains($0) ? $0 : nil }
        let title: String? = (dict?["title"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        return ParsedLocation(
            lastReadAt: parsedTimestamp ?? fallbackUpdated,
            progressFraction: progress,
            progressLabel: title
        )
    }

    private struct ParsedLocation {
        let lastReadAt: Date
        let progressFraction: Double?
        let progressLabel: String?
    }

    /// Shared ISO8601 parser. Sendable because `ISO8601DateFormatter`
    /// is thread-safe in Foundation per Apple's docs.
    private static let timestampFormatter: ISO8601DateFormatter = ISO8601DateFormatter()
}
