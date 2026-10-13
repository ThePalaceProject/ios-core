//
//  TPPBookRegistryLoadedAccountTests.swift
//  PalaceTests
//
//  The registry reports which library's records it holds. The offline queue
//  compares it with the current library, so an absent book is never read as a
//  confirmed return before that library's shelf has loaded.
//

import XCTest
import Combine
@testable import Palace
@testable import PalaceBookRegistry

private final class SwitchableAccountScope: AccountScopeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _current: String?

    init(_ current: String) { _current = current }

    var currentAccountID: String? { lock.withLock { _current } }
    /// Silent: the test drives loads itself rather than through the
    /// registry's run-loop-delivered account-change reload.
    var accountDidChangePublisher: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func hasCredentials(forAccount accountID: String) -> Bool { false }
    func loansURL(forAccount accountID: String, readinessTimeout: TimeInterval) async throws -> URL? { nil }

    func setCurrent(_ accountID: String) {
        lock.withLock { _current = accountID }
    }
}

@MainActor
final class TPPBookRegistryLoadedAccountTests: XCTestCase {

    private var tempDir: URL!
    private var appContainer: AppContainer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoadedAccount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        appContainer = makeTestAppContainer()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        appContainer = nil
        try super.tearDownWithError()
    }

    private func makeRegistry(scope: SwitchableAccountScope) -> TPPBookRegistry {
        let dir = tempDir!
        let container = appContainer!
        return TPPBookRegistry(
            accountScope: scope,
            imageLoader: MockImageLoader(),
            dependencies: RegistryExternalDependencies(
                downloadService: { container.downloadCenter },
                loansFeedFetcher: { container.opdsFeedService },
                sideloadedIdentifiers: { [] },
                registryDirectory: { dir.appendingPathComponent($0) },
                onAvailabilityChange: { _, _ in }
            )
        )
    }

    private func load(_ registry: TPPBookRegistry) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.load(account: nil) { continuation.resume() }
        }
    }

    func testLoad_recordsTheLoadedLibrary() async {
        let registry = makeRegistry(scope: SwitchableAccountScope("lib-A"))
        XCTAssertNil(registry.loadedAccountID, "precondition: nothing loaded yet")

        await load(registry)

        XCTAssertEqual(registry.loadedAccountID, "lib-A")
    }

    /// After the current library changes, the registry still names the old
    /// library until a load of the new one finishes.
    func testLoadAfterLibrarySwitch_namesTheNewLibraryOnlyOnceLoaded() async {
        let scope = SwitchableAccountScope("lib-A")
        let registry = makeRegistry(scope: scope)
        await load(registry)

        scope.setCurrent("lib-B")
        let beforeReload = registry.loadedAccountID
        await load(registry)

        XCTAssertEqual(beforeReload, "lib-A", "the store still holds A until B loads")
        XCTAssertEqual(registry.loadedAccountID, "lib-B")
    }

    func testReset_ofTheLoadedLibrary_clearsIt() async {
        let registry = makeRegistry(scope: SwitchableAccountScope("lib-A"))
        await load(registry)

        registry.reset("lib-A")

        XCTAssertNil(registry.loadedAccountID)
    }

    func testReset_ofAnotherLibrary_keepsTheLoadedOne() async {
        let registry = makeRegistry(scope: SwitchableAccountScope("lib-A"))
        await load(registry)

        registry.reset("lib-B")

        XCTAssertEqual(registry.loadedAccountID, "lib-A")
    }
}
