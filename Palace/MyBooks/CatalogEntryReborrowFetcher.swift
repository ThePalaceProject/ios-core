//
//  CatalogEntryReborrowFetcher.swift
//  Palace
//
//  The production `CatalogEntryFetcher` the no-active-loan borrow retry uses
//  (PP-5397). A book's stored acquisitions are fulfillment links scoped to its
//  loan, so once the loan ends the catalog entry at `alternateURL` is the only
//  place a usable borrow link survives.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceCatalog
import PalaceLogging

enum CatalogEntryReborrowFetcher {

    /// Re-reads a book's catalog entry through `feedFetcher`.
    ///
    /// Depends on the narrow `OPDSFeedFetching` rather than the `OPDSFeedService`
    /// actor so a test can supply a fixture feed without the Obj-C feed bridge
    /// and a real request.
    ///
    /// `resetCache: true` is load-bearing: the retry runs seconds after the
    /// download failure, well inside the feed cache's life, and a cached entry
    /// is as likely to carry the dead loan's links as the stored record does.
    ///
    /// Returns nil rather than throwing on every failure. The caller treats nil
    /// as "retry with the stored book", which is no better than before this
    /// path existed but no worse, and still spends the patron's attempt.
    static func make(feedFetcher: any OPDSFeedFetching) -> CatalogEntryFetcher {
        { book in
            guard let url = book.alternateURL else { return nil }
            do {
                let feed = try await feedFetcher.fetchFeed(from: url, resetCache: true)
                guard let entry = feed.entries.first as? TPPOPDSEntry else {
                    Log.warn(#file, "Catalog entry feed for \(book.identifier) carried no entries")
                    return nil
                }
                return TPPBook(entry: entry)
            } catch {
                Log.warn(#file, "Could not re-read the catalog entry for \(book.identifier): \(error.localizedDescription)")
                return nil
            }
        }
    }
}
