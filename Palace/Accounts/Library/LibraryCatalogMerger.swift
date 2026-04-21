import Foundation

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
