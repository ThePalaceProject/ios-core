//
//  RelatedBooksService.swift
//  Palace
//
//  "Other books by this author" / related-works lanes for the book detail
//  screen, extracted from `BookDetailViewModel` (god-class decomposition plan
//  §3a-4 / Wave 5).
//
//  The service owns the feed fetch and the grouped-feed -> lanes derivation. The
//  view model keeps the parts that are view-model state: which book the lanes
//  belong to, the loading flag, and the rule that a non-empty set of lanes is
//  never replaced by an empty one.
//
//  The derivation had no reachable test seam before this file: its only input
//  was the return value of a concrete `OPDSFeedService` actor, constructed
//  inside the view model. `RelatedBooksFeedFetcher` is that seam, and
//  `RelatedBooksServiceTests` is what it made writable.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry
import PalaceCatalog
import PalaceLogging

/// One horizontal lane of related books, plus the "more" destination its
/// grouping link points at.
struct BookLane {
    let title: String
    let books: [TPPBook]
    let subsectionURL: URL?
}

/// Fetches a related-works feed. Injected as a closure so a test can supply a
/// parsed fixture feed without the `OPDSFeedService` actor and the Obj-C feed
/// bridge behind it.
typealias RelatedBooksFeedFetcher = (URL) async throws -> TPPOPDSFeed

@MainActor
struct RelatedBooksService {

    private let fetcher: RelatedBooksFeedFetcher
    private let registry: TPPBookRegistryProvider

    init(fetcher: @escaping RelatedBooksFeedFetcher, registry: TPPBookRegistryProvider) {
        self.fetcher = fetcher
        self.registry = registry
    }

    /// Fetches `url` and derives its lanes.
    ///
    /// Returns nil for every outcome that must leave the currently-displayed
    /// lanes alone: a fetch failure, or a feed that is not
    /// `.acquisitionGrouped`. An empty dictionary means "the feed was grouped
    /// and yielded no lanes", which is a different answer — the caller decides
    /// whether to apply it.
    func fetchLanes(from url: URL, authorName: String?) async -> [String: BookLane]? {
        do {
            let feed = try await fetcher(url)
            return Self.lanes(from: feed, registry: registry, authorName: authorName)
        } catch {
            Log.warn(#file, "Failed to fetch related books: \(error.localizedDescription)")
            return nil
        }
    }

    /// Groups a related-works feed's entries into lanes by their grouping link's
    /// title, keeping the first `href` seen for each group as that lane's "more"
    /// destination. Entries without a grouping link, and entries that do not map
    /// to a book, are skipped.
    ///
    /// Returns nil for a feed that is not `.acquisitionGrouped` — the related
    /// lanes are only defined for the grouped shape.
    static func lanes(from feed: TPPOPDSFeed,
                      registry: TPPBookRegistryProvider,
                      authorName: String?) -> [String: BookLane]? {
        guard feed.type == .acquisitionGrouped else { return nil }

        var groupTitleToBooks: [String: [TPPBook]] = [:]
        var groupTitleToMoreURL: [String: URL?] = [:]
        if let entries = feed.entries as? [TPPOPDSEntry] {
            for entry in entries {
                guard let group = entry.groupAttributes else { continue }
                let groupTitle = group.title ?? ""
                if let book = CatalogViewModel.makeBook(from: entry, bookRegistry: registry) {
                    groupTitleToBooks[groupTitle, default: []].append(book)
                    if groupTitleToMoreURL[groupTitle] == nil { groupTitleToMoreURL[groupTitle] = group.href }
                }
            }
        }

        var lanesMap = [String: BookLane]()
        for (title, books) in groupTitleToBooks {
            lanesMap[title] = BookLane(title: title, books: books, subsectionURL: groupTitleToMoreURL[title] ?? nil)
        }

        // Hoist the lane containing the current book's author ahead of the rest.
        // Carried over verbatim from the view model. Worth knowing when reading
        // it: the result is a Dictionary, which has no defined order, so this
        // re-insertion changes no key and no value — the lane order the screen
        // renders is decided where the dictionary is consumed, not here.
        if let author = authorName, !author.isEmpty,
           let authorLane = lanesMap.first(where: { $0.value.books.contains(where: { $0.authors?.contains(author) ?? false }) }) {
            lanesMap.removeValue(forKey: authorLane.key)
            var reordered = [String: BookLane]()
            reordered[authorLane.key] = authorLane.value
            reordered.merge(lanesMap) { _, new in new }
            lanesMap = reordered
        }

        return lanesMap
    }
}
