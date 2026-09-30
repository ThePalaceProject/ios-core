//
//  BookMetadataService.swift
//  Palace
//
//  Metadata hydration for the book detail screen. Grouped-lane feeds can carry
//  lightweight entries without issued date, publisher, distributor or
//  categories; re-fetching the single-entry feed at `alternateURL` fills them in
//  without disturbing the lane entry's navigational fields. The post-await
//  re-checks stay in the view model because a related-book navigation can change
//  `self.book` while the fetch is in flight.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceCatalog
import PalaceLogging

/// Fetches the full OPDS entry for a book from its `alternateURL`. Injected as a
/// closure so a test can supply a fixture entry, or suspend, without standing up
/// the `OPDSFeedService` actor and the Obj-C feed bridge behind it.
typealias BookMetadataFetcher = (URL) async throws -> TPPBook?

@MainActor
struct BookMetadataService {

    private let fetcher: BookMetadataFetcher

    init(fetcher: @escaping BookMetadataFetcher) {
        self.fetcher = fetcher
    }

    /// True when every field hydration can fill is blank. All six must be blank:
    /// a book that already carries any one of them came from a full entry, so a
    /// re-fetch would spend a request to learn nothing.
    static func needsHydration(_ book: TPPBook) -> Bool {
        book.published == nil
            && (book.publisher?.isEmpty ?? true)
            && (book.distributor?.isEmpty ?? true)
            && (book.categoryStrings?.isEmpty ?? true)
            && (book.audience?.isEmpty ?? true)
            && (book.language?.isEmpty ?? true)
    }

    /// Fetches the full entry for `book`, or nil when there is nothing to fetch
    /// (already hydrated, no `alternateURL`) or the fetch failed. A failure is
    /// logged and swallowed: hydration is a display enrichment, and a patron who
    /// cannot reach the alternate feed should still see the book they navigated to.
    func fetchFullEntry(for book: TPPBook) async -> TPPBook? {
        guard Self.needsHydration(book) else { return nil }
        guard let url = book.alternateURL else { return nil }
        do {
            return try await fetcher(url)
        } catch {
            Log.warn(#file, "Failed to hydrate book metadata: \(error.localizedDescription)")
            return nil
        }
    }

    /// Merges a freshly-fetched entry into the book on screen.
    ///
    /// Three rules, and which one a field gets is load-bearing:
    ///  - identity and navigational fields (identifier, title, acquisitions,
    ///    the annotations/analytics/alternate/relatedWorks/revoke/report/
    ///    timeTracking URLs, authors, contributors, updated, imageCache) are
    ///    taken from `current` unconditionally — the lane entry is authoritative
    ///    for them and the alternate feed can disagree,
    ///  - blank-string fields take `fresh` only when `current` is empty or nil,
    ///  - optional-value fields fall back to `fresh` only when `current` is nil.
    static func merge(into current: TPPBook, fresh: TPPBook) -> TPPBook {
        TPPBook(
            acquisitions: current.acquisitions,
            authors: current.bookAuthors,
            categoryStrings: (current.categoryStrings?.isEmpty ?? true) ? fresh.categoryStrings : current.categoryStrings,
            distributor: (current.distributor?.isEmpty ?? true) ? fresh.distributor : current.distributor,
            identifier: current.identifier,
            imageURL: current.imageURL ?? fresh.imageURL,
            imageThumbnailURL: current.imageThumbnailURL ?? fresh.imageThumbnailURL,
            published: current.published ?? fresh.published,
            publisher: (current.publisher?.isEmpty ?? true) ? fresh.publisher : current.publisher,
            subtitle: current.subtitle ?? fresh.subtitle,
            summary: (current.summary?.isEmpty ?? true) ? fresh.summary : current.summary,
            title: current.title,
            updated: current.updated,
            annotationsURL: current.annotationsURL,
            analyticsURL: current.analyticsURL,
            alternateURL: current.alternateURL,
            relatedWorksURL: current.relatedWorksURL,
            previewLink: current.previewLink ?? fresh.previewLink,
            seriesURL: current.seriesURL ?? fresh.seriesURL,
            seriesName: (current.seriesName?.isEmpty ?? true) ? fresh.seriesName : current.seriesName,
            revokeURL: current.revokeURL,
            reportURL: current.reportURL,
            timeTrackingURL: current.timeTrackingURL,
            contributors: current.contributors,
            bookDuration: (current.bookDuration?.isEmpty ?? true) ? fresh.bookDuration : current.bookDuration,
            audience: (current.audience?.isEmpty ?? true) ? fresh.audience : current.audience,
            language: (current.language?.isEmpty ?? true) ? fresh.language : current.language,
            imageCache: current.imageCache
        )
    }
}
