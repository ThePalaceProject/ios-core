//
//  AccountsManagerInitPreloadGateTests.swift
//  PalaceTests
//
//  `AccountsManager.init` hydrates accounts from the on-disk registry cache in
//  production, and skips that work when XCTest hosts the process unless a test
//  opts in. The cache is an in-memory double, so no test touches Application Support.
//

import XCTest
@testable import Palace

@MainActor
final class AccountsManagerInitPreloadGateTests: PalaceWiringTestCase {

    private static let xcTestEnvironment = ["XCTestConfigurationFilePath": "/tmp/fixture.xctestconfiguration"]

    private var feedData: Data!
    private var savedDeferDiskPreload = true

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "OPDS2CatalogsFeed", withExtension: "json") else {
            XCTFail("OPDS2CatalogsFeed.json fixture missing from PalaceTests bundle")
            return
        }
        feedData = try Data(contentsOf: url)
        savedDeferDiskPreload = AccountsManager.deferDiskCachePreloadForTesting
    }

    override func tearDownWithError() throws {
        AccountsManager.deferDiskCachePreloadForTesting = savedDeferDiskPreload
        feedData = nil
        try super.tearDownWithError()
    }

    /// Outside XCTest, init hydrates the cached registry even with the test-only
    /// deferral set: the flag must not change simulator, developer or TestFlight launches.
    func testInit_outsideXCTest_preloadsCachedAccountsEvenWhenDeferralIsSet() {
        AccountsManager.deferDiskCachePreloadForTesting = true

        let manager = makeManager(environment: [:])

        XCTAssertFalse(manager.accounts().isEmpty,
                       "A non-XCTest launch must hydrate accounts from the disk cache during init")
    }

    /// Under XCTest the default skips the preload, so the unit-test host launch does
    /// not decode every cached library account.
    func testInit_underXCTest_byDefault_skipsCachedAccountPreload() {
        let manager = makeManager(environment: Self.xcTestEnvironment)

        XCTAssertTrue(manager.accounts().isEmpty,
                      "Under XCTest, init must not hydrate the disk cache unless a test opts in")
    }

    /// A test that needs init-time hydration opts in by clearing the deferral.
    func testInit_underXCTest_whenTestOptsIn_preloadsCachedAccounts() {
        AccountsManager.deferDiskCachePreloadForTesting = false

        let manager = makeManager(environment: Self.xcTestEnvironment)

        XCTAssertFalse(manager.accounts().isEmpty,
                       "Opting in must restore the init-time disk-cache preload under XCTest")
    }

    // MARK: - Helpers

    private func makeManager(environment: [String: String]) -> AccountsManager {
        makeFreshAccountsManager(
            defaults: Self.testUserDefaults(),
            registryCache: FreshCatalogCache(data: feedData),
            processEnvironment: environment
        )
    }
}

/// Reports a fresh cached catalog for every hash and serves the fixture bytes.
/// Writes and clears are no-ops; the slim snapshot is absent so init takes the full path.
private final class FreshCatalogCache: AccountRegistryCaching, @unchecked Sendable {
    private let data: Data
    init(data: Data) { self.data = data }

    func writeCatalogData(_ data: Data, hash: String, isBundled: Bool) {}
    func readCatalogData(hash: String) -> Data? { data }
    func hasFreshCatalogData(hash: String) -> Bool { true }
    func isCatalogStale(hash: String) -> Bool { false }
    func slimSnapshotURL(hash: String) -> URL? { nil }
    func clearFileCaches() {}
}
