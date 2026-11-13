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

    /// Two reconnects while the retry fetch is still in flight start one fetch:
    /// the second finds `.detailsLoading` and the single-flight guard dedupes it.
    func testReconnect_TwiceWhileRetryInFlight_FetchesOnce() async throws {
        launchOffline()
        getter.holdsCompletion = true

        connectivity.send(true)
        connectivity.send(true)

        XCTAssertEqual(getter.callCount, 2, "one launch fetch, one retry for two reconnect events")
        getter.isOnline = true
        getter.completeHeld()
        _ = try await account.awaitReady(timeout: 2)
    }

    /// The first binding on a manager is accepted, so the composition root's
    /// call takes effect.
    func testBindOnce_OnUnboundManager_IsAccepted() {
        let unbound = makeFreshAccountsManager(defaults: Self.testUserDefaults())

        let bound = unbound.reloadCurrentAccountWhenConnected(PassthroughSubject<Bool, Never>().eraseToAnyPublisher())

        XCTAssertTrue(bound)
        XCTAssertTrue(unbound._hasReconnectSubscriptionForTesting)
    }

    /// A second binding keeps the first: events on the second publisher do not
    /// fetch, and the first still drives the account.
    func testBindTwice_KeepsFirstSubscription() {
        let second = PassthroughSubject<Bool, Never>()

        let rebound = manager.reloadCurrentAccountWhenConnected(second.eraseToAnyPublisher())

        XCTAssertFalse(rebound, "a second binding is refused")
        launchOffline()
        getter.isOnline = true
        second.send(true)
        XCTAssertEqual(getter.callCount, 1, "the refused binding does not drive the account")
        connectivity.send(true)
        XCTAssertEqual(getter.callCount, 2, "the first binding still drives the account")
    }

    /// The test-boundary cancel also ends the reconnect subscription.
    func testCancelBackgroundWork_EndsReconnectSubscription() {
        XCTAssertTrue(manager._hasReconnectSubscriptionForTesting, "precondition: bound in setUp")

        manager.cancelBackgroundWork()

        XCTAssertFalse(manager._hasReconnectSubscriptionForTesting)
    }

    /// The composition root binds the manager's reconnect drive. Built through the
    /// production builder rather than read from the cached graph.
    func testProductionWiring_BindsAccountsManagerToReachability() {
        let container = AppContainer._buildCachedAppContainer()
        defer { container.accountsManager.cancelAndDrainBackgroundWork() }

        XCTAssertTrue(container.accountsManager._hasReconnectSubscriptionForTesting,
                      "the composition root binds the reconnect drive")
        XCTAssertFalse(container.accountsManager.reloadCurrentAccountWhenConnected(Empty<Bool, Never>().eraseToAnyPublisher()),
                       "the binding is already taken by the container's reachability")
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
/// document once online. With `holdsCompletion`, keeps the request in flight
/// until `completeHeld()`. Counts every request.
private final class SwitchableAuthDocGetter: AuthDocumentGetting, @unchecked Sendable {
    private let onlineData: Data
    var isOnline = false
    var holdsCompletion = false
    private(set) var callCount = 0
    private var held: [(NYPLResult<Data>) -> Void] = []

    func completeHeld() {
        let pending = held
        held.removeAll()
        holdsCompletion = false
        pending.forEach { respond($0) }
    }

    init(onlineData: Data) {
        self.onlineData = onlineData
    }

    func get(_ url: URL, completion: @escaping (NYPLResult<Data>) -> Void) {
        callCount += 1
        if holdsCompletion {
            held.append(completion)
        } else {
            respond(completion)
        }
    }

    private func respond(_ completion: (NYPLResult<Data>) -> Void) {
        if isOnline {
            completion(.success(onlineData, nil))
        } else {
            completion(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), nil))
        }
    }
}
