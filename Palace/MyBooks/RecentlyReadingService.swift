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
    /// Most-recently-opened audiobook (via the wall-clock open-time
    /// tracker), along with that open timestamp, regardless of whether
    /// there's an active session right now. Used by
    /// `ActiveSessionsViewModel` as a fallback for the Continue row's
    /// `mostRecent` candidate when the app cold-launches after the
    /// user previously listened to an audiobook. The open timestamp
    /// is returned so callers can compare it against a recently-opened
    /// ebook's `lastReadAt` to pick whichever the user touched most
    /// recently (without the timestamp, the row would always prefer
    /// the audiobook even when a more-recently-opened ebook exists).
    func recentlyOpenedAudiobook() -> (book: TPPBook, openedAt: Date)?
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
    /// Polish-phase (in-app-nav-polish-2026-06-01) — optional source of
    /// truth for the actual wall-clock open time of each book. When
    /// provided, its `lastOpened(_:)` value takes priority over the
    /// renderer-specific timestamp parsing fallback (which for
    /// EPUB/PDF degrades to `book.updated` and produces wrong sort).
    /// Optional so existing tests + production callers that don't
    /// inject it keep their pre-polish behavior.
    private let bookOpenTracker: BookOpenTracking?

    init(bookRegistry: TPPBookRegistryProvider,
         clock: @escaping () -> Date = Date.init,
         bookOpenTracker: BookOpenTracking? = nil) {
        self.bookRegistry = bookRegistry
        self.clock = clock
        self.bookOpenTracker = bookOpenTracker
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
            // Include a book the patron actually opened even if its reading
            // position hasn't persisted yet: the reader saves location
            // asynchronously, so right after an open the tracker has a
            // wall-clock open time while `location` is still nil. Audiobooks
            // already qualify on open-time alone (see `recentlyOpenedAudiobook`),
            // so gating ebooks on a saved location made a freshly-opened ebook
            // fail to supersede a Continue-slot audiobook until some unrelated
            // refresh. Exclude only books with neither a saved location NOR a
            // recorded open (i.e. genuinely never opened).
            let openedAt = bookOpenTracker?.lastOpened(book.identifier)
            let location = bookRegistry.location(forIdentifier: book.identifier)
            guard location != nil || openedAt != nil else { return nil }
            // Polish-phase last-read accuracy fix
            // (in-app-nav-polish-2026-06-01): prefer the BookOpenTracker's
            // wall-clock open time over parsed location timestamp /
            // book.updated fallback. Without this, EPUB / PDF locations
            // (which don't embed a timeStamp in their JSON) all fall back
            // to `book.updated` — the OPDS feed's catalog-update date —
            // so the Continue Reading row shows the book with the
            // newest catalog entry, NOT the book the user actually
            // opened most recently.
            let parsed = location.map { parseLocation($0, fallbackUpdated: book.updated, now: now) }
            let lastReadAt = openedAt ?? parsed?.lastReadAt ?? book.updated
            return ContinueReadingItem(
                bookId: book.identifier,
                book: book,
                contentType: contentType,
                lastReadAt: lastReadAt,
                progressFraction: parsed?.progressFraction,
                progressLabel: parsed?.progressLabel
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

    /// Polish-phase (in-app-nav-polish-2026-06-01) — most-recently-opened
    /// audiobook in the user's registry, sorted by `bookOpenTracker`
    /// wall-clock open time. Returns nil when no audiobooks have ever
    /// been opened OR when no tracker is injected (legacy callers).
    ///
    /// Used by `ActiveSessionsViewModel` as the fallback for the
    /// Continue row's `mostRecent` candidate when there's no active
    /// audiobook session right now (cold launch).
    func recentlyOpenedAudiobook() -> (book: TPPBook, openedAt: Date)? {
        guard let bookOpenTracker = bookOpenTracker else { return nil }
        return bookRegistry.myBooks
            .filter { $0.defaultBookContentType == .audiobook }
            .compactMap { book -> (book: TPPBook, openedAt: Date)? in
                guard let date = bookOpenTracker.lastOpened(book.identifier) else { return nil }
                return (book: book, openedAt: date)
            }
            .sorted { $0.openedAt > $1.openedAt }
            .first
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
