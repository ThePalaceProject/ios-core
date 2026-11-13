//
//  TPPReauthenticatorTests.swift
//  PalaceTests
//
//  Tests for reauthentication handling
//

import XCTest
@testable import Palace

/// Note: TPPReauthenticator requires UI presentation (SignInModalPresenter) which cannot
/// be tested in unit tests. Use TPPReauthenticatorMockTests for testing reauthentication logic.
@MainActor
final class TPPReauthenticatorTests: XCTestCase {

    // MARK: - Properties

    private var reauthenticator: TPPReauthenticator!
    private var userAccount: TPPUserAccountMock!

    // MARK: - Setup/Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        reauthenticator = TPPReauthenticator()
        userAccount = TPPUserAccountMock()
    }

    override func tearDownWithError() throws {
        reauthenticator = nil
        userAccount = nil
        try super.tearDownWithError()
    }

    // MARK: - Initialization Tests

    func testInit_createsDistinctInstances() {
        // The type is not a singleton — each init must produce a distinct
        // object. This matters because TPPReauthenticator holds per-call
        // presentation state; a shared instance would leak cookies/context
        // between reauth attempts that happen close together.
        let second = TPPReauthenticator()
        let third = TPPReauthenticator()

        XCTAssertFalse(reauthenticator === second,
                       "first and second instances must be distinct")
        XCTAssertFalse(reauthenticator === third,
                       "first and third instances must be distinct")
        XCTAssertFalse(second === third,
                       "second and third instances must be distinct")
    }

    func testInit_isNSObjectSubclass() {
        XCTAssertTrue(reauthenticator is NSObject)
        // Objective-C interoperability: must also respond to basic NSObject messages
        XCTAssertNotNil(reauthenticator.description,
                        "NSObject subclass must provide a non-nil description")
    }

    func testInit_conformsToReauthenticatorProtocol() {
        XCTAssertTrue(reauthenticator is Reauthenticator)
        // Verify through protocol type rather than concrete type
        let asProtocol: Reauthenticator? = reauthenticator as? Reauthenticator
        XCTAssertNotNil(asProtocol,
                        "TPPReauthenticator must be castable to the Reauthenticator protocol")
    }

    func testAuthenticateIfNeeded_withNilCompletion_stillPresentsSignIn() async {
        // Background auth-refresh paths (e.g. token expiry mid-sync) call
        // authenticateIfNeeded with a nil completion because they don't need
        // to observe the result; the sign-in prompt must still be shown.
        // A spy presenter stands in for the real modal, which would otherwise
        // land on the host window after the test ends.
        var presentations = 0
        let spy = SignInModalSheetPresenter(
            appContainer: AppContainer.production(), // MIGRATED-DEFERRED: withSignInModalSheetPresenter() derives from the production container, as in SignInModalLifecycleTests.
            currentAccountIDProvider: { "reauthenticator-tests" },
            needsAuthProvider: { _ in true },
            driver: { _, _, completion in
                presentations += 1
                completion()
            }
        )
        TPPReauthenticator._testContainerOverride = AppContainer.production().withSignInModalSheetPresenter(spy) // MIGRATED-DEFERRED: see above.
        defer { TPPReauthenticator._testContainerOverride = nil }

        reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true, authenticationCompletion: nil)
        reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false, authenticationCompletion: nil)

        await reauthenticator._awaitPendingAuthenticationsForTesting()
        XCTAssertEqual(presentations, 2)
    }
}

// MARK: - Mock Reauthenticator Tests

@MainActor
final class TPPReauthenticatorMockTests: XCTestCase {

    private var mockReauthenticator: TPPReauthenticatorMock!
    private var userAccount: TPPUserAccountMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        mockReauthenticator = TPPReauthenticatorMock()
        userAccount = TPPUserAccountMock()
    }

    override func tearDownWithError() throws {
        mockReauthenticator = nil
        userAccount = nil
        try super.tearDownWithError()
    }

    func testMockReauthenticator_tracksReauthPerformed() {
        XCTAssertFalse(mockReauthenticator.authenticateIfNeededCalled)

        mockReauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true, authenticationCompletion: nil)

        XCTAssertTrue(mockReauthenticator.authenticateIfNeededCalled)
    }

    func testMockReauthenticator_callsCompletion() {
        // Swift 6: the completion is @Sendable, so a captured counter var can't
        // be mutated inside it — box it.
        let completionCallCount = LockIsolated<Int>(0)
        mockReauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true) {
            completionCallCount.withValue { $0 += 1 }
        }
        // The mock must call the completion (unlike the real implementation which needs UI)
        XCTAssertEqual(completionCallCount.value, 1,
                       "Mock reauthenticator must call the completion exactly once")
        XCTAssertTrue(mockReauthenticator.authenticateIfNeededCalled,
                      "authenticateIfNeededCalled flag must be set after completion")
    }
}
