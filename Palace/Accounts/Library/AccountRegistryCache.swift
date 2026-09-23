//
//  AccountRegistryCache.swift
//  Palace
//
//  god-class decomposition — Wave 3 / 3a-1 (the first in-target collaborator
//  split out of `AccountsManager`).
//
//  The on-disk catalog cache concern: the stale-while-revalidate metadata value
//  type and the FileManager-backed read/write/staleness/clear operations the
//  registry loader and launch-preload paths use. Extracted behind an injected
//  `AccountRegistryCaching` seam so the hub carries no disk-I/O body and the
//  collaborator is a spy-testable double — the `AccountNetworking` / S3 precedent.
//  Travels into `PalaceAccounts` with `AccountsManager` at the package move.
//
//  `Sendable`: catalog writes/reads run inside the loader's owned-crawl
//  `@Sendable` Tasks (`spawnOwnedCrawlTask`), so the injected cache must cross that
//  boundary. `DiskAccountRegistryCache` is a stateless value type, so the
//  conformance is free.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - Cache Metadata

/// Metadata for tracking cache freshness in stale-while-revalidate pattern
struct CatalogCacheMetadata: Codable {
    let timestamp: Date
    let hash: String
    /// `true` when this cache entry was populated from the build-time
    /// bundled snapshot (`Palace/Accounts/Library/bundled_registry.json`),
    /// `false` for entries written from a network response. Bundled-origin
    /// caches return `true` from `isStale(serverMaxAge:now:)` regardless
    /// of timestamp so the refresh trigger keeps firing on every
    /// `loadCatalogs` call until a real network response overwrites the
    /// metadata with `isBundled = false`. Decodes as `false` for legacy
    /// metadata files written before this field existed.
    let isBundled: Bool

    init(timestamp: Date, hash: String, isBundled: Bool = false) {
        self.timestamp = timestamp
        self.hash = hash
        self.isBundled = isBundled
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, hash, isBundled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.hash = try container.decode(String.self, forKey: .hash)
        self.isBundled = try container.decodeIfPresent(Bool.self, forKey: .isBundled) ?? false
    }

    /// Default stale TTL: 6 hours (half the server's typical Cache-Control
    /// max-age of 12hr). Overridden dynamically by `staleTTL(serverMaxAge:)`.
    private static let defaultStaleTTL: TimeInterval = 21600

    /// Cache expires after 24 hours (must not be used)
    private static let maxAge: TimeInterval = 86400

    /// Returns the stale TTL, dynamically adjusted from the server's
    /// Cache-Control max-age if available. Uses half the server's value
    /// with a floor of 5 minutes and a ceiling of 12 hours.
    static func staleTTL(serverMaxAge: TimeInterval?) -> TimeInterval {
        guard let serverMax = serverMaxAge, serverMax > 0 else {
            return defaultStaleTTL
        }
        let half = serverMax / 2
        return min(max(half, 300), 43200) // clamp to [5min, 12hr]
    }

    /// Returns true if cache is stale given the server's max-age hint.
    func isStale(serverMaxAge: TimeInterval?) -> Bool {
        isStale(serverMaxAge: serverMaxAge, now: Date())
    }

    func isStale(serverMaxAge: TimeInterval?, now: Date) -> Bool {
        // Bundled-origin caches are always stale for refresh purposes
        // regardless of timestamp. The bundled bytes are usable for
        // immediate display but not authoritative, so refresh has to
        // keep firing until a real network response overwrites with
        // `isBundled = false`.
        if isBundled { return true }
        return now.timeIntervalSince(timestamp) > Self.staleTTL(serverMaxAge: serverMaxAge)
    }

    /// Returns true if cache is stale using the default TTL (no server hint).
    var isStale: Bool {
        isStale(serverMaxAge: nil)
    }

    /// Returns true if cache is expired (older than 24 hours)
    var isExpired: Bool {
        isExpired(now: Date())
    }

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(timestamp) > Self.maxAge
    }

    /// Pure staleness predicate over an optional metadata + server hint.
    /// Returns `true` when metadata is missing (⇒ refresh) OR when the metadata
    /// reports staleness against `serverMaxAge`. Lives on the metadata type (it
    /// is metadata logic) so the nil-metadata → refresh path stays unit-testable
    /// without touching the file system (F-013). Moved from `AccountsManager` in
    /// the Wave 3 / 3a-1 disk-cache extraction.
    static func isCacheStale(
        metadata: CatalogCacheMetadata?,
        serverMaxAge: TimeInterval?
    ) -> Bool {
        guard let metadata else {
            // No metadata means we should refresh
            return true
        }
        return metadata.isStale(serverMaxAge: serverMaxAge)
    }
}

// MARK: - Registry cache seam

/// The disk-cache surface `AccountsManager` consumes on the launch-preload,
/// `loadCatalogs` stale-while-revalidate, and `clearCache` paths. Declared beside
/// the hub (moves into `PalaceAccounts` at the package move); `DiskAccountRegistryCache`
/// is the production implementation, tests inject a recording double.
protocol AccountRegistryCaching: Sendable {
    /// Persist catalog bytes for `hash` and stamp fresh metadata. `isBundled`
    /// distinguishes build-time-snapshot writes from authoritative network writes
    /// so staleness logic keeps refresh alive on bundled-origin caches.
    func writeCatalogData(_ data: Data, hash: String, isBundled: Bool)

    /// The catalog blob for `hash`, or nil if absent/unreadable.
    func readCatalogData(hash: String) -> Data?

    /// True if cached data exists and is not expired (may be stale but usable).
    /// Probes existence with `fileExists` — never reads the ~2.4MB blob.
    func hasFreshCatalogData(hash: String) -> Bool

    /// True if cache exists and is stale (needs a background refresh).
    func isCatalogStale(hash: String) -> Bool

    /// On-disk location of the CP-D1 slim launch snapshot for `hash`.
    func slimSnapshotURL(hash: String) -> URL?

    /// Delete all on-disk catalog/metadata/list/crawl caches (the `clearCache`
    /// file sweep). Does NOT touch the network response cache — that is the
    /// caller's `networkExecutor.clearCache()` (the `AccountNetworking` seam).
    func clearFileCaches()
}

extension AccountRegistryCaching {
    /// Convenience for the common network-write path (`isBundled: false`). A
    /// protocol requirement can't carry a default argument, and the concrete
    /// impl's default is invisible through the `any AccountRegistryCaching`
    /// existential — this restores the call-site ergonomics the hub relied on.
    func writeCatalogData(_ data: Data, hash: String) {
        writeCatalogData(data, hash: hash, isBundled: false)
    }
}

/// `FileManager`-backed production `AccountRegistryCaching`. Stateless ⇒ `Sendable`.
struct DiskAccountRegistryCache: AccountRegistryCaching {

    func writeCatalogData(_ data: Data, hash: String, isBundled: Bool) {
        // Save catalog data
        guard let url = accountsCatalogUrl(hash: hash) else { return }
        try? data.write(to: url)

        // Save metadata with current timestamp. `isBundled` distinguishes
        // build-time-snapshot writes from authoritative network writes so
        // staleness logic can keep refresh alive on bundled-origin caches.
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: hash, isBundled: isBundled)
        if let metadataUrl = cacheMetadataUrl(hash: hash),
           let metadataData = try? JSONEncoder().encode(metadata) {
            try? metadataData.write(to: metadataUrl)
        }
    }

    func readCatalogData(hash: String) -> Data? {
        guard let url = accountsCatalogUrl(hash: hash) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Returns true if cached data exists and is not expired (can be stale but usable).
    ///
    /// Existence is probed with `FileManager.fileExists` — NOT a full
    /// `Data(contentsOf:)` — so this check never reads the ~2.4MB catalog blob
    /// off disk. The single authoritative byte read happens exactly once per
    /// launch at the caller (`preloadAccountsFromDiskCacheSync` and the
    /// `loadCatalogs` stale-while-revalidate branch), which pair this gate with
    /// one `readCatalogData` and thread those bytes into the decode.
    func hasFreshCatalogData(hash: String) -> Bool {
        guard let url = accountsCatalogUrl(hash: hash),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let metadata = readCacheMetadata(hash: hash) else {
            // Data exists but no metadata - treat as usable but stale
            return false
        }
        return !metadata.isExpired
    }

    func isCatalogStale(hash: String) -> Bool {
        let metadata = readCacheMetadata(hash: hash)
        let serverMaxAge = readCrawlState(hash: hash)?.serverMaxAge
        return CatalogCacheMetadata.isCacheStale(metadata: metadata, serverMaxAge: serverMaxAge)
    }

    /// On-disk location of the CP-D1 slim launch snapshot (current + settings
    /// accounts). The `accounts_catalog_slim_` name shares the
    /// `accounts_catalog_` prefix, so `clearFileCaches()` and the wiring-suite
    /// disk-cache purge already sweep it with no extra bookkeeping. CP-D1.
    func slimSnapshotURL(hash: String) -> URL? {
        guard let appSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        else { return nil }
        return appSupport.appendingPathComponent("accounts_catalog_slim_\(hash).json")
    }

    func clearFileCaches() {
        // file caches — delete all files matching known prefixes written to the
        // Application Support root. (`authentication_document_` was removed: no
        // code path writes a file with that prefix — auth docs live in `Account`
        // state / are re-fetched, not persisted as files — so it cleared nothing.)
        let prefixes = [
            "library_list_",
            "accounts_catalog_",
            "accounts_catalog_metadata_",
            "crawl_state_",
        ]
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        guard let files = try? fm.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files {
            let name = file.lastPathComponent
            if prefixes.contains(where: { name.hasPrefix($0) }) {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - Private disk helpers

    private func accountsCatalogUrl(hash: String) -> URL? {
        guard let appSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        else { return nil }
        return appSupport.appendingPathComponent("accounts_catalog_\(hash).json")
    }

    private func cacheMetadataUrl(hash: String) -> URL? {
        guard let appSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        else { return nil }
        return appSupport.appendingPathComponent("accounts_catalog_metadata_\(hash).json")
    }

    /// Reads cache metadata for the given hash
    private func readCacheMetadata(hash: String) -> CatalogCacheMetadata? {
        guard let url = cacheMetadataUrl(hash: hash),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CatalogCacheMetadata.self, from: data)
    }

    /// Reads crawl state for the given hash (used for dynamic TTL adjustment)
    private func readCrawlState(hash: String) -> CrawlState? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        let url = appSupport.appendingPathComponent("crawl_state_\(hash).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CrawlState.self, from: data)
    }
}
