import Foundation
import PalaceCatalog

/// Result of merging crawled publications into the existing catalog.
struct MergeResult {
    /// The complete merged list of publications.
    let publications: [OPDS2Publication]

    /// UUIDs of publications whose thumbnail URL changed during the
    /// merge (or that are brand-new). The caller should evict cached
    /// logo images for these UUIDs so fresh images are fetched.
    let uuidsWithChangedLogos: Set<String>
}

/// Merges incremental or full crawl results into the existing catalog.
enum LibraryCatalogMerger {

    /// Merges `updates` into `existing` publications.
    ///
    /// - **Incremental mode** (`isFullCrawl == false`): existing
    ///   publications not present in `updates` are preserved. Updated
    ///   publications (matched by `metadata.id`) are replaced.
    ///
    /// - **Full crawl mode** (`isFullCrawl == true`): the result
    ///   contains only the `updates`. Publications absent from `updates`
    ///   are deleted.
    ///
    /// In both modes, the returned `uuidsWithChangedLogos` set contains
    /// IDs where the thumbnail URL differs between old and new, plus
    /// IDs of entirely new publications.
    static func merge(
        existing: [OPDS2Publication],
        updates: [OPDS2Publication],
        isFullCrawl: Bool
    ) -> MergeResult {
        let existingByID = Dictionary(
            existing.map { ($0.metadata.id, $0) },
            uniquingKeysWith: { _, last in last }
        )

        var changedLogos = Set<String>()

        // Detect logo changes in updates
        for pub in updates {
            let id = pub.metadata.id
            if let old = existingByID[id] {
                if old.thumbnailURL != pub.thumbnailURL {
                    changedLogos.insert(id)
                }
            } else {
                // New publication — logo needs fetching
                changedLogos.insert(id)
            }
        }

        if isFullCrawl {
            return MergeResult(
                publications: updates,
                uuidsWithChangedLogos: changedLogos
            )
        }

        // Incremental: start with existing, overlay updates
        var mergedByID = existingByID
        for pub in updates {
            mergedByID[pub.metadata.id] = pub
        }

        // Preserve original ordering: existing first, then new additions
        var seen = Set<String>()
        var merged = [OPDS2Publication]()

        for pub in existing {
            let id = pub.metadata.id
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            merged.append(mergedByID[id] ?? pub)
        }

        for pub in updates {
            let id = pub.metadata.id
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            merged.append(pub)
        }

        return MergeResult(
            publications: merged,
            uuidsWithChangedLogos: changedLogos
        )
    }

    // MARK: - Feed completeness (PP-5191)

    /// Whether a feed is a PARTIAL view of the registry rather than the whole of it.
    ///
    /// PP-5191. The registry's crawlable endpoint pages at 100 over ~1457 libraries
    /// and every page declares the true total in `metadata.numberOfItems`. Nothing
    /// used that: a 100-row page-1 response and a complete 1457-row crawl were
    /// indistinguishable once written to disk, so a partial page could — and did —
    /// replace the whole registry, leaving a patron's library unresolvable and the
    /// app reporting them signed out.
    ///
    /// **`numberOfItems == nil` means COMPLETE, deliberately.** Unknown provenance is
    /// trusted so this predicate can only ever flag a feed we *positively know* is
    /// short. That is load-bearing, not a convenience: `serializeAsCatalogsFeed` did
    /// not carry the field until this change, so every already-shipped on-disk cache
    /// decodes `nil`; `PalaceTests/OPDS2CatalogsFeed.json` (171 catalogs, no such
    /// field) backs five Accounts suites; and the direct-GET recovery endpoint
    /// `/libraries` does not emit it at all (measured 2026-09-21: 1457 catalogs, no
    /// `numberOfItems`). Reading `nil` as PARTIAL would have refused the app's own
    /// cache on the first launch after upgrade — an empty registry for every install,
    /// rendering exactly like a normal cold-cache launch.
    ///
    /// The separate question of whether a feed may DELETE rows is not this predicate's
    /// to answer — see `AccountRegistryStore.replaceBucket`, which requires positively
    /// asserted completeness for that, precisely because `nil` is trusted here.
    static func feedIsPartial(metadata: OPDS2CatalogsFeed.Metadata, catalogCount: Int) -> Bool {
        guard let declared = metadata.numberOfItems else { return false }
        return catalogCount < declared
    }

    /// Convenience over a decoded feed. Same rule as `feedIsPartial(metadata:catalogCount:)`,
    /// which is the single definition — do not add a second one.
    static func feedIsPartial(_ feed: OPDS2CatalogsFeed) -> Bool {
        feedIsPartial(metadata: feed.metadata, catalogCount: feed.catalogs.count)
    }

    /// Whether a feed POSITIVELY asserts it is the whole registry.
    ///
    /// Deliberately NOT `!feedIsPartial(...)`. The two answer different questions and
    /// conflating them is the defect this separation exists to prevent:
    ///
    ///   * `feedIsPartial == false` means "not KNOWN to be short" — it is true for a
    ///     feed carrying no `numberOfItems` at all, because unknown provenance is
    ///     trusted for the purpose of not REFUSING a write.
    ///   * `feedIsPositivelyComplete == true` means the feed SAID how many libraries
    ///     exist and carries that many.
    ///
    /// Only the second may license DELETING libraries. `loadAccountSetsAndAuthDoc`
    /// DERIVES its INV-2 input from this predicate for every caller that does not
    /// override it, so no entry point can forget. The reachable difference is the
    /// direct-GET fallbacks, which fetch the non-crawlable `/libraries` — measured
    /// 2026-09-21: 1457 catalogs and NO `numberOfItems`. Under `!feedIsPartial` that
    /// response would be complete by fiat and whatever it contained would become the
    /// registry, on the code path that runs precisely when the network is already
    /// misbehaving.
    static func feedIsPositivelyComplete(metadata: OPDS2CatalogsFeed.Metadata, catalogCount: Int) -> Bool {
        guard let declared = metadata.numberOfItems else { return false }
        return catalogCount == declared
    }

    /// Convenience over a decoded feed. See `feedIsPositivelyComplete(metadata:catalogCount:)`.
    static func feedIsPositivelyComplete(_ feed: OPDS2CatalogsFeed) -> Bool {
        feedIsPositivelyComplete(metadata: feed.metadata, catalogCount: feed.catalogs.count)
    }

    /// Serializes a list of publications back to `OPDS2CatalogsFeed`
    /// JSON format for disk caching. The feed uses `catalogs` as the
    /// key (matching the registry's non-crawlable endpoint format).
    static func serializeAsCatalogsFeed(
        publications: [OPDS2Publication],
        metadata: OPDS2CatalogsFeed.Metadata
    ) -> Data? {
        let feed = OPDS2CatalogsFeed(
            catalogs: publications,
            links: [],
            metadata: metadata,
            facets: nil
        )
        return try? OPDS2CatalogsFeed.encode(feed)
    }
}

// MARK: - OPDS2CatalogsFeed encoding helper

extension OPDS2CatalogsFeed {
    /// Encodes the feed to JSON data using the same date format as `fromData`.
    static func encode(_ feed: OPDS2CatalogsFeed) throws -> Data {
        let encoder = JSONEncoder()

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"

        encoder.dateEncodingStrategy = .formatted(formatter)
        return try encoder.encode(feed)
    }
}
