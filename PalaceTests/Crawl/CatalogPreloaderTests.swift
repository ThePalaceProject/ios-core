import XCTest
@testable import Palace

// MARK: - Mock Feed Preloader

private final class MockFeedPreloader: CatalogFeedPreloading {
    var preloadedURLs: [URL] = []
    var urlsThatShouldFail: Set<URL> = []

    func preloadFeed(from url: URL) async throws {
        preloadedURLs.append(url)
        if urlsThatShouldFail.contains(url) {
            throw URLError(.notConnectedToInternet)
        }
    }
}

// MARK: - Tests

final class CatalogPreloaderTests: XCTestCase {

    private func makeAccount(uuid: String, catalogUrl: String?) -> Account {
        var links = [OPDS2Link]()
        if let url = catalogUrl {
            links.append(OPDS2Link(href: url, rel: "http://opds-spec.org/catalog"))
        }
        let pub = OPDS2Publication(
            links: links,
            metadata: OPDS2Publication.Metadata(id: uuid, title: "Library \(uuid)"),
            images: nil
        )
        return Account(publication: pub, imageCache: MockImageCache())
    }

    func testPreloader_PreloadsCurrentAccountCatalog() async {
        let feedPreloader = MockFeedPreloader()
        let preloader = CatalogPreloader(feedPreloader: feedPreloader)

        let current = makeAccount(uuid: "current", catalogUrl: "https://example.com/current/catalog")

        await preloader.preloadCatalogs(
            currentAccount: current,
            recentAccountUUIDs: [],
            accountProvider: { _ in nil }
        )

        XCTAssertEqual(feedPreloader.preloadedURLs.count, 1)
        XCTAssertEqual(feedPreloader.preloadedURLs.first, URL(string: "https://example.com/current/catalog"))
    }

    func testPreloader_PreloadsRecentlyUsedAccounts_UpToLimit() async {
        let feedPreloader = MockFeedPreloader()
        let preloader = CatalogPreloader(feedPreloader: feedPreloader, maxPreload: 3)

        let currentURL = URL(string: "https://example.com/current/catalog")!
        let urlA = URL(string: "https://example.com/a/catalog")!
        let urlB = URL(string: "https://example.com/b/catalog")!
        let urlC = URL(string: "https://example.com/c/catalog")!
        let urlD = URL(string: "https://example.com/d/catalog")!

        let current = makeAccount(uuid: "current", catalogUrl: currentURL.absoluteString)
        let accounts: [String: Account] = [
            "a": makeAccount(uuid: "a", catalogUrl: urlA.absoluteString),
            "b": makeAccount(uuid: "b", catalogUrl: urlB.absoluteString),
            "c": makeAccount(uuid: "c", catalogUrl: urlC.absoluteString),
            "d": makeAccount(uuid: "d", catalogUrl: urlD.absoluteString),
        ]

        await preloader.preloadCatalogs(
            currentAccount: current,
            recentAccountUUIDs: ["a", "b", "c", "d"],
            accountProvider: { accounts[$0] }
        )

        // maxPreload=3 caps the recents list at 3, plus the current account = 4 total.
        // The fourth recent (urlD) must be dropped. Assertions are exact so mutations
        // to the guard (`<` → `<=`, break → continue, etc.) actually fail.
        let preloaded = Set(feedPreloader.preloadedURLs)
        XCTAssertEqual(preloaded, [currentURL, urlA, urlB, urlC])
        XCTAssertFalse(preloaded.contains(urlD), "Fourth recent must be skipped by the maxPreload cap")
    }

    func testPreloader_SkipsAccountsWithNoCatalogURL() async {
        let feedPreloader = MockFeedPreloader()
        let preloader = CatalogPreloader(feedPreloader: feedPreloader)

        let current = makeAccount(uuid: "current", catalogUrl: "https://example.com/current/catalog")
        let noCatalog = makeAccount(uuid: "no-catalog", catalogUrl: nil)

        await preloader.preloadCatalogs(
            currentAccount: current,
            recentAccountUUIDs: ["no-catalog"],
            accountProvider: { _ in noCatalog }
        )

        // Only current account preloaded
        XCTAssertEqual(feedPreloader.preloadedURLs.count, 1)
    }

    func testPreloader_SkipsDuplicateCurrentAccount() async {
        let feedPreloader = MockFeedPreloader()
        let preloader = CatalogPreloader(feedPreloader: feedPreloader)

        let current = makeAccount(uuid: "current", catalogUrl: "https://example.com/current/catalog")

        await preloader.preloadCatalogs(
            currentAccount: current,
            recentAccountUUIDs: ["current"], // same as current
            accountProvider: { _ in current }
        )

        // Should only preload once, not twice
        XCTAssertEqual(feedPreloader.preloadedURLs.count, 1)
    }

    func testPreloader_ContinuesOnFailure() async {
        let feedPreloader = MockFeedPreloader()
        let preloader = CatalogPreloader(feedPreloader: feedPreloader, maxPreload: 3)

        let currentURL = URL(string: "https://example.com/current/catalog")!
        let flakyURL = URL(string: "https://example.com/flaky/catalog")!
        let healthyURL = URL(string: "https://example.com/healthy/catalog")!

        feedPreloader.urlsThatShouldFail = [flakyURL]

        let current = makeAccount(uuid: "current", catalogUrl: currentURL.absoluteString)
        let accounts: [String: Account] = [
            "flaky": makeAccount(uuid: "flaky", catalogUrl: flakyURL.absoluteString),
            "healthy": makeAccount(uuid: "healthy", catalogUrl: healthyURL.absoluteString),
        ]

        // One recent preload throws; the others must still be attempted and the
        // whole call must return normally. If the catch inside the TaskGroup were
        // removed (re-throwing), `preloadCatalogs` would become throws — which
        // would be a compile error rather than a runtime one — and the healthy
        // sibling wouldn't be reached.
        await preloader.preloadCatalogs(
            currentAccount: current,
            recentAccountUUIDs: ["flaky", "healthy"],
            accountProvider: { accounts[$0] }
        )

        XCTAssertEqual(Set(feedPreloader.preloadedURLs), [currentURL, flakyURL, healthyURL])
    }

    func testPreloader_NilCurrentAccount_StillPreloadsRecent() async {
        let feedPreloader = MockFeedPreloader()
        let preloader = CatalogPreloader(feedPreloader: feedPreloader)

        let account = makeAccount(uuid: "a", catalogUrl: "https://example.com/a/catalog")

        await preloader.preloadCatalogs(
            currentAccount: nil,
            recentAccountUUIDs: ["a"],
            accountProvider: { _ in account }
        )

        XCTAssertEqual(feedPreloader.preloadedURLs.count, 1)
    }
}

// MockImageCache is defined in PalaceTests/Mocks/MockImageCache.swift
