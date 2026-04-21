import Foundation

/// Abstraction for preloading a feed URL. Allows mocking in tests.
protocol CatalogFeedPreloading {
    func preloadFeed(from url: URL) async throws
}

/// Must use `UnifiedOPDSService` rather than `OPDSFeedService`: some library
/// roots (e.g. Lyrasis Reads) redirect to `application/opds+json`, which the
/// OPDS1-only path rejects and surfaces as a "Failed to preload catalog"
/// error even though the Catalog tab's OPDS2 parser loads it fine.
struct OPDSFeedPreloader: CatalogFeedPreloading {
    func preloadFeed(from url: URL) async throws {
        _ = try await UnifiedOPDSService.shared.fetchFeed(
            from: url,
            preferOPDS2: true,
            useToken: false,
            forceRefresh: false
        )
    }
}

/// Preloads catalog root feeds for active accounts after a registry
/// crawl completes, so the Catalog tab and account switching feel
/// instant.
///
/// Runs as a low-priority background operation. Failures are silently
/// logged — preloading is best-effort and should never block the user.
final class CatalogPreloader {

    private let feedPreloader: CatalogFeedPreloading
    private let maxPreload: Int

    init(
        feedPreloader: CatalogFeedPreloading = OPDSFeedPreloader(),
        maxPreload: Int = 5
    ) {
        self.feedPreloader = feedPreloader
        self.maxPreload = maxPreload
    }

    /// Preloads catalog root feeds for the current account and recently-
    /// used accounts.
    ///
    /// - Parameters:
    ///   - currentAccount: The currently active library account (always preloaded first).
    ///   - recentAccountUUIDs: UUIDs of recently-used accounts from settings.
    ///   - accountProvider: Closure to look up an Account by UUID.
    func preloadCatalogs(
        currentAccount: Account?,
        recentAccountUUIDs: [String],
        accountProvider: (String) -> Account?
    ) async {
        var preloadedUUIDs = Set<String>()
        var urlsToPreload = [(uuid: String, url: URL)]()

        // Current account first
        if let current = currentAccount,
           let urlString = current.catalogUrl,
           let url = URL(string: urlString) {
            urlsToPreload.append((current.uuid, url))
            preloadedUUIDs.insert(current.uuid)
        }

        // Recently-used accounts (up to maxPreload)
        for uuid in recentAccountUUIDs {
            guard !preloadedUUIDs.contains(uuid) else { continue }
            guard urlsToPreload.count < maxPreload + 1 else { break } // +1 for current

            if let account = accountProvider(uuid),
               let urlString = account.catalogUrl,
               let url = URL(string: urlString) {
                urlsToPreload.append((uuid, url))
                preloadedUUIDs.insert(uuid)
            }
        }

        // Preload concurrently with limited concurrency
        await withTaskGroup(of: Void.self) { group in
            for (uuid, url) in urlsToPreload {
                group.addTask { [feedPreloader] in
                    do {
                        try await feedPreloader.preloadFeed(from: url)
                        Log.debug(#file, "Preloaded catalog for account \(uuid)")
                    } catch {
                        Log.debug(#file, "Failed to preload catalog for \(uuid): \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
