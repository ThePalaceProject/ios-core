//
//  SignInSyncDeferralTests.swift
//  PalaceTests
//
//  The sign-in change syncs in My Books and Holds (PP-5508): while the app is
//  not visible they wait and run once on the next transition to visible.
//  Patron-initiated refreshes still sync at once.
//

import Combine
import PalacePreferences
import XCTest
@testable import Palace

@MainActor
final class SignInSyncDeferralTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var container: AppContainer!
    private var scheduler: FakeActivityTickScheduler!
    private var policy: ActivityPolicy!
    /// Starts at `.loggedOut`; the view models drop the replayed first value.
    private var authState: CurrentValueSubject<TPPAccountAuthState, Never>!

    override func setUp() {
        super.setUp()
        registry = TPPBookRegistryMock()
        container = makeTestAppContainer()
        scheduler = FakeActivityTickScheduler()
        policy = makeTestActivityPolicy(scheduler: scheduler)
        authState = CurrentValueSubject(.loggedOut)
    }

    override func tearDown() {
        registry = nil
        container = nil
        scheduler = nil
        policy = nil
        authState = nil
        super.tearDown()
    }

    private func makeMyBooks(hasCredentials: Bool = true) -> MyBooksViewModel {
        MyBooksViewModel(
            bookRegistry: registry,
            accountsManager: container.accountsManager,
            settings: TPPSettings(),
            downloadCenter: container.downloadCenter,
            isUserAuthorizedForRegistry: { true },
            isOnline: { true },
            hasCredentials: { hasCredentials },
            authStateChanges: authState.eraseToAnyPublisher(),
            activityPolicy: policy
        )
    }

    private func makeHolds() -> HoldsViewModel {
        HoldsViewModel(
            bookRegistry: registry,
            accountsManager: container.accountsManager,
            settings: TPPSettings(),
            debugSettings: container.debugSettings,
            hasCredentials: { true },
            debounceInterval: 0,
            accountDidChange: Empty().eraseToAnyPublisher(),
            authStateChanges: authState.eraseToAnyPublisher(),
            activityPolicy: policy
        )
    }

    /// Holds' refresh syncs a library that needs sign-in and loads one that
    /// does not; the test container's library is either, so count both.
    private var holdsRefreshCount: Int { registry.syncCallCount + registry.loadCallCount }

    private func signIn() async {
        authState.send(.loggedIn)
        await drainMainQueueAsync()
    }

    // MARK: - My Books

    func testMyBooksSignIn_inBackground_marksPendingAndSyncsOnceWhenVisible() async {
        let viewModel = makeMyBooks()
        let before = registry.syncCallCount

        await signIn()
        XCTAssertEqual(registry.syncCallCount, before, "no sync while nothing is visible")

        policy.setScene(.inactive)
        XCTAssertEqual(registry.syncCallCount, before + 1, "the pending sync runs on becoming visible")

        policy.setScene(.active)
        policy.setScene(.background)
        policy.setScene(.active)
        XCTAssertEqual(registry.syncCallCount, before + 1, "the pending sync runs only once")
        withExtendedLifetime(viewModel) {}
    }

    func testMyBooksSignIn_twiceInBackground_runsOneSyncWhenVisible() async {
        let viewModel = makeMyBooks()
        let before = registry.syncCallCount

        await signIn()
        authState.send(.credentialsStale)
        await signIn()
        policy.setScene(.active)

        XCTAssertEqual(registry.syncCallCount, before + 1)
        withExtendedLifetime(viewModel) {}
    }

    func testMyBooksSignIn_whileVisible_syncsImmediately() async {
        policy.setScene(.active)
        let viewModel = makeMyBooks()
        let before = registry.syncCallCount

        await signIn()

        XCTAssertEqual(registry.syncCallCount, before + 1)
        withExtendedLifetime(viewModel) {}
    }

    func testMyBooksSignIn_inBackgroundWithCarPlayConnected_syncsImmediately() async {
        policy.setCarPlayConnected(true)
        let viewModel = makeMyBooks()
        let before = registry.syncCallCount

        await signIn()

        XCTAssertEqual(registry.syncCallCount, before + 1, "a connected CarPlay screen counts as visible")
        withExtendedLifetime(viewModel) {}
    }

    func testMyBooksSignIn_withoutCredentials_neverSyncs() async {
        let viewModel = makeMyBooks(hasCredentials: false)
        let before = registry.syncCallCount

        await signIn()
        policy.setScene(.active)

        XCTAssertEqual(registry.syncCallCount, before)
        withExtendedLifetime(viewModel) {}
    }

    /// Pull to refresh is the patron asking, so it is not deferred.
    func testMyBooksPullToRefresh_inBackground_syncsImmediately() {
        let viewModel = makeMyBooks()
        let before = registry.syncCallCount

        viewModel.reloadData()

        XCTAssertEqual(registry.syncCallCount, before + 1)
    }

    // MARK: - Holds

    func testHoldsSignIn_inBackground_marksPendingAndRefreshesOnceWhenVisible() async {
        let viewModel = makeHolds()
        let before = holdsRefreshCount

        await signIn()
        XCTAssertEqual(holdsRefreshCount, before, "no refresh while nothing is visible")

        policy.setScene(.active)
        XCTAssertEqual(holdsRefreshCount, before + 1)

        policy.setScene(.background)
        policy.setScene(.inactive)
        XCTAssertEqual(holdsRefreshCount, before + 1, "the pending refresh runs only once")
        withExtendedLifetime(viewModel) {}
    }

    func testHoldsSignIn_inBackgroundWithCarPlayConnected_refreshesImmediately() async {
        policy.setCarPlayConnected(true)
        let viewModel = makeHolds()
        let before = holdsRefreshCount

        await signIn()

        XCTAssertEqual(holdsRefreshCount, before + 1)
        withExtendedLifetime(viewModel) {}
    }

    func testHoldsPullToRefresh_inBackground_refreshesImmediately() {
        let viewModel = makeHolds()
        let before = holdsRefreshCount

        viewModel.refresh()

        XCTAssertEqual(holdsRefreshCount, before + 1)
    }
}
