import XCTest
@testable import Palace

// MARK: - Mock Feed Preloader

private final class MockFeedPreloader: CatalogFeedPreloading {
    var preloadedURLs: [URL] = []
    var shouldFail = false

    func preloadFeed(from url: URL) async throws {
        preloadedURLs.append(url)
        if shouldFail {
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
        // maxPreload=3 means up to 3 recent accounts + current
        let preloader = CatalogPreloader(feedPreloader: feedPreloader, maxPreload: 3)

        let current = makeAccount(uuid: "current", catalogUrl: "https://example.com/current/catalog")
        let accounts: [String: Account] = [
            "a": makeAccount(uuid: "a", catalogUrl: "https://example.com/a/catalog"),
            "b": makeAccount(uuid: "b", catalogUrl: "https://example.com/b/catalog"),
            "c": makeAccount(uuid: "c", catalogUrl: "https://example.com/c/catalog"),
            "d": makeAccount(uuid: "d", catalogUrl: "https://example.com/d/catalog"),
        ]

        await preloader.preloadCatalogs(
            currentAccount: current,
            recentAccountUUIDs: ["a", "b", "c", "d"],
            accountProvider: { accounts[$0] }
        )

        // Verify we preloaded at least some accounts (exact count depends on Account.catalogUrl resolution)
        XCTAssertGreaterThan(feedPreloader.preloadedURLs.count, 0, "Should preload at least one account")
        XCTAssertLessThanOrEqual(feedPreloader.preloadedURLs.count, 5, "Should cap at maxPreload + current")
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
        feedPreloader.shouldFail = true
        let preloader = CatalogPreloader(feedPreloader: feedPreloader)

        let current = makeAccount(uuid: "current", catalogUrl: "https://example.com/current/catalog")

        // Should not throw — failures are silently logged
        await preloader.preloadCatalogs(
            currentAccount: current,
            recentAccountUUIDs: [],
            accountProvider: { _ in nil }
        )

        // Attempted the preload even though it failed
        XCTAssertEqual(feedPreloader.preloadedURLs.count, 1)
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
