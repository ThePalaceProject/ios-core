//
//  AccountReconnectReloadTests.swift
//
//  A launch made offline leaves the current account at `.detailsFailed`, and
//  `awaitReady()` then throws at once, so the post-return registry sync fails
//  with "Account not found" (PP-5492). When the connection returns, the
//  manager fetches the authentication document again.
//

import Combine
import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountReconnectReloadTests: PalaceWiringTestCase {

    private var libraryAccountMock: TPPLibraryAccountMock!
    private var account: Account!
    private var getter: SwitchableAuthDocGetter!
    private var connectivity: PassthroughSubject<Bool, Never>!
    private var manager: AccountsManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        libraryAccountMock = TPPLibraryAccountMock()
        account = libraryAccountMock.tppAccount
        // The state a cold launch reaches before the first fetch: no details yet.
        account.authenticationDocument = nil
        account.details = nil
        account._setState(.basicInfoLoaded)
        let authDocData = try Data(contentsOf: libraryAccountMock.nyplAuthDocURL)
        getter = SwitchableAuthDocGetter(onlineData: authDocData)
        account.authDocumentGetter = getter

        manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        manager._seedAccountForTesting(account)
        connectivity = PassthroughSubject<Bool, Never>()
        manager.reloadCurrentAccountWhenConnected(connectivity.eraseToAnyPublisher())
    }

    override func tearDownWithError() throws {
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        manager = nil
        connectivity = nil
        getter = nil
        account = nil
        libraryAccountMock = nil
        try super.tearDownWithError()
    }

    /// Offline launch, then the connection returns: the current account loads its
    /// details, so the registry sync's readiness gate returns the loans URL.
    func testOfflineLaunch_WhenConnectionReturns_CurrentAccountLoadsDetails() async throws {
        launchOffline()

        getter.isOnline = true
        connectivity.send(true)

        let details = try await account.awaitReady(timeout: 2)
        XCTAssertNotNil(details.loansUrl, "the post-return sync reads the loans URL from these details")
        XCTAssertEqual(getter.callCount, 2, "one failed launch fetch, one fetch on reconnect")
    }

    /// Losing the connection does not start a fetch; only a return to online does.
    func testOfflineLaunch_WhenConnectionDropsAgain_DoesNotFetch() {
        launchOffline()

        connectivity.send(false)

        XCTAssertEqual(getter.callCount, 1, "only the launch fetch ran")
        guard case .detailsFailed = account.loadState else {
            return XCTFail("state was \(account.loadState), expected .detailsFailed")
        }
    }

    /// A reconnect after the details already loaded does not fetch them again.
    func testReconnect_WhenDetailsAlreadyLoaded_DoesNotFetchAgain() {
        getter.isOnline = true
        manager.driveCurrentAccountAuthDocIfNeeded()
        guard case .detailsLoaded = account.loadState else {
            return XCTFail("precondition: state was \(account.loadState), expected .detailsLoaded")
        }

        connectivity.send(true)

        XCTAssertEqual(getter.callCount, 1, "loaded details are not fetched again on reconnect")
    }

    /// A reconnect that fails again leaves the failure in place, and the next
    /// reconnect retries once more.
    func testReconnect_WhenStillUnreachable_RetriesOnNextReconnect() async throws {
        launchOffline()

        connectivity.send(true)
        guard case .detailsFailed = account.loadState else {
            return XCTFail("state was \(account.loadState), expected .detailsFailed after a failed retry")
        }

        getter.isOnline = true
        connectivity.send(true)

        _ = try await account.awaitReady(timeout: 2)
        XCTAssertEqual(getter.callCount, 3)
    }

    // MARK: - Helpers

    /// Runs the launch drive with no connection and checks it left `.detailsFailed`.
    private func launchOffline(file: StaticString = #filePath, line: UInt = #line) {
        getter.isOnline = false
        manager.driveCurrentAccountAuthDocIfNeeded()
        guard case .detailsFailed(.authDocumentFetchFailed) = account.loadState else {
            return XCTFail("precondition: offline launch left \(account.loadState)", file: file, line: line)
        }
    }
}

/// Completes synchronously: a not-connected error while offline, the auth
/// document once online. Counts every request.
private final class SwitchableAuthDocGetter: AuthDocumentGetting, @unchecked Sendable {
    private let onlineData: Data
    var isOnline = false
    private(set) var callCount = 0

    init(onlineData: Data) {
        self.onlineData = onlineData
    }

    func get(_ url: URL, completion: @escaping (NYPLResult<Data>) -> Void) {
        callCount += 1
        if isOnline {
            completion(.success(onlineData, nil))
        } else {
            completion(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), nil))
        }
    }
}
