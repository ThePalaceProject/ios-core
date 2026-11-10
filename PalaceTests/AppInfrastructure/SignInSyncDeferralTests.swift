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
    /// Read by the view models at request time and again when a pending sync runs.
    private var signedIn = true
    private var signInPresentations = 0

    override func setUp() {
        super.setUp()
        registry = TPPBookRegistryMock()
        container = makeTestAppContainer()
        scheduler = FakeActivityTickScheduler()
        policy = makeTestActivityPolicy(scheduler: scheduler)
        authState = CurrentValueSubject(.loggedOut)
        signedIn = true
        signInPresentations = 0
    }

    override func tearDown() {
        registry = nil
        container = nil
        scheduler = nil
        policy = nil
        authState = nil
        super.tearDown()
    }

    private func makeMyBooks() -> MyBooksViewModel {
        MyBooksViewModel(
            bookRegistry: registry,
            accountsManager: container.accountsManager,
            settings: TPPSettings(),
            downloadCenter: container.downloadCenter,
            isUserAuthorizedForRegistry: { true },
            isOnline: { true },
            hasCredentials: { [unowned self] in self.signedIn },
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
            hasCredentials: { [unowned self] in self.signedIn },
            presentSignIn: { [unowned self] _ in self.signInPresentations += 1 },
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
        signedIn = false
        let viewModel = makeMyBooks()
        let before = registry.syncCallCount

        await signIn()
        policy.setScene(.active)

        XCTAssertEqual(registry.syncCallCount, before)
        withExtendedLifetime(viewModel) {}
    }

    /// A sign-out while the sync waits must not let it run: with no
    /// credentials, reloadData would open a sign-in sheet nobody asked for.
    func testMyBooksSignIn_inBackgroundThenSignedOut_doesNotSyncWhenVisible() async {
        let viewModel = makeMyBooks()
        let before = registry.syncCallCount

        await signIn()
        signedIn = false
        policy.setScene(.active)

        XCTAssertEqual(registry.syncCallCount, before)
        withExtendedLifetime(viewModel) {}
    }

    func testMyBooksSignIn_pendingThenCarPlayConnects_syncsOnce() async {
        let viewModel = makeMyBooks()
        let before = registry.syncCallCount

        await signIn()
        policy.setCarPlayConnected(true)
        policy.setScene(.active)

        XCTAssertEqual(registry.syncCallCount, before + 1, "CarPlay connecting runs the pending sync, once")
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

    func testHoldsSignIn_inBackgroundThenSignedOut_neitherRefreshesNorPresentsSignIn() async {
        let viewModel = makeHolds()
        let before = holdsRefreshCount

        await signIn()
        signedIn = false
        policy.setScene(.active)

        XCTAssertEqual(holdsRefreshCount, before)
        XCTAssertEqual(signInPresentations, 0)
        withExtendedLifetime(viewModel) {}
    }

    func testHoldsSignIn_withoutCredentials_neverRefreshes() async {
        signedIn = false
        let viewModel = makeHolds()
        let before = holdsRefreshCount

        await signIn()
        policy.setScene(.active)

        XCTAssertEqual(holdsRefreshCount, before)
        XCTAssertEqual(signInPresentations, 0)
        withExtendedLifetime(viewModel) {}
    }

    func testHoldsSignIn_twiceInBackground_refreshesOnceWhenVisible() async {
        let viewModel = makeHolds()
        let before = holdsRefreshCount

        await signIn()
        authState.send(.credentialsStale)
        await signIn()
        policy.setScene(.active)

        XCTAssertEqual(holdsRefreshCount, before + 1)
        withExtendedLifetime(viewModel) {}
    }

    func testHoldsSignIn_pendingThenCarPlayConnects_refreshesOnce() async {
        let viewModel = makeHolds()
        let before = holdsRefreshCount

        await signIn()
        policy.setCarPlayConnected(true)
        policy.setScene(.active)

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
