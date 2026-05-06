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

    func testAuthenticateIfNeeded_withNilCompletion_doesNotCrash() {
        // Background auth-refresh paths (e.g. token expiry mid-sync) call
        // authenticateIfNeeded with a nil completion because they don't need
        // to observe the result. Must not crash, must not corrupt shared state
        // (the userAccount instance must remain usable for the main flow).
        let userAccountBefore = userAccount

        reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true, authenticationCompletion: nil)
        reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false, authenticationCompletion: nil)

        XCTAssertNotNil(reauthenticator,
                        "Reauthenticator must remain valid after authenticateIfNeeded calls")
        XCTAssertTrue(userAccount === userAccountBefore,
                      "authenticateIfNeeded must not swap out the caller's userAccount reference")
    }
}

// MARK: - Mock Reauthenticator Tests

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
        var completionCallCount = 0
        mockReauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true) {
            completionCallCount += 1
        }
        // The mock must call the completion (unlike the real implementation which needs UI)
        XCTAssertEqual(completionCallCount, 1,
                       "Mock reauthenticator must call the completion exactly once")
        XCTAssertTrue(mockReauthenticator.authenticateIfNeededCalled,
                      "authenticateIfNeededCalled flag must be set after completion")
    }
}

// MARK: - SAMLReauthCoordinator Tests

/// Tests for the single-flight coordinator that auto-presents the SAML/OIDC
/// re-auth modal when /patrons/me/ returns 401. Without these guards we'd
/// stack a modal per polling 401 (every 30s while stale) — these tests
/// pin the gates that keep that from happening. HelpSpot 17716.
@MainActor
final class SAMLReauthCoordinatorTests: XCTestCase {

    private var mockReauthenticator: TPPReauthenticatorMock!
    private var userAccount: TPPUserAccountMock!
    private var coordinator: SAMLReauthCoordinator!
    private var appState: UIApplication.State = .active

    override func setUpWithError() throws {
        try super.setUpWithError()
        mockReauthenticator = TPPReauthenticatorMock()
        userAccount = TPPUserAccountMock()
        userAccount.setBarcode("barcode", PIN: "pin")
        userAccount.setAuthState(.credentialsStale)
        appState = .active
        coordinator = SAMLReauthCoordinator(
            reauthenticator: mockReauthenticator,
            applicationStateProvider: { [weak self] in self?.appState ?? .active }
        )
    }

    override func tearDownWithError() throws {
        coordinator = nil
        userAccount = nil
        mockReauthenticator = nil
        try super.tearDownWithError()
    }

    // MARK: - Happy path

    func testRequestReauth_browserStrategy_andStaleAndActive_invokesReauthenticator() {
        let auth = makeAuthentication(.saml)

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: URL(string: "https://example.org/patrons/me/"))

        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 1,
                       "Browser-based reauth on a stale, foreground account must call the reauthenticator exactly once")
        XCTAssertEqual(mockReauthenticator.lastUsingExistingCredentials, true,
                       "Coordinator must pass usingExistingCredentials=true so the SAML helper short-circuits to the IdP web view")
    }

    func testRequestReauth_oidcStrategy_invokesReauthenticator() {
        // OIDC also resolves to .browser via reauthStrategy. Verifies the
        // coordinator doesn't accidentally hard-code SAML.
        let auth = makeAuthentication(.oidc)

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)

        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 1,
                       "OIDC must trigger the same reauth path as SAML — both have reauthStrategy == .browser")
    }

    // MARK: - Strategy gate

    func testRequestReauth_basicAuth_doesNotInvokeReauthenticator() {
        // Basic auth uses a credential prompt, not the modal — token-refresh
        // path or local prompt handles it. Coordinator must skip.
        let auth = makeAuthentication(.basic)

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)

        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 0,
                       "Basic-auth reauth must NOT go through SAMLReauthCoordinator — wrong UX")
    }

    func testRequestReauth_tokenAuth_doesNotInvokeReauthenticator() {
        let auth = makeAuthentication(.token)

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)

        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 0,
                       "Token-refresh path is owned by TPPNetworkExecutor — coordinator must not race with it")
    }

    func testRequestReauth_nilAuthDef_doesNotInvokeReauthenticator() {
        coordinator.requestReauth(for: userAccount, authDef: nil, triggerURL: nil)

        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 0,
                       "A nil authDef means we don't know the strategy yet — must not present a modal")
    }

    // MARK: - State gate

    func testRequestReauth_loggedInState_doesNotInvokeReauthenticator() {
        // A logged-in account that hits this path means somebody upstream
        // skipped markCredentialsStale. We must NOT flash a modal at a
        // working session — it'd wipe their cookies on cancel.
        userAccount.setAuthState(.loggedIn)
        let auth = makeAuthentication(.saml)

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)

        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 0,
                       "Logged-in account must never see an unsolicited reauth modal")
    }

    func testRequestReauth_loggedOutState_doesNotInvokeReauthenticator() {
        // .loggedOut means the user explicitly signed out. Don't auto-prompt.
        userAccount.setAuthState(.loggedOut)
        let auth = makeAuthentication(.saml)

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)

        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 0,
                       "Logged-out account must not be auto-prompted — they intentionally signed out")
    }

    // MARK: - App state gate

    func testRequestReauth_backgroundApp_doesNotInvokeReauthenticator() {
        // Background polls happen via NSURLSession refresh; we must not
        // queue a modal that pops the moment the app comes forward —
        // surprises the user. The next /patrons/me/ poll once foreground
        // re-triggers the call.
        appState = .background
        let auth = makeAuthentication(.saml)

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)

        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 0,
                       "Background app must not present the reauth modal")
    }

    func testRequestReauth_inactiveApp_doesNotInvokeReauthenticator() {
        // .inactive = transitioning, e.g. control center pulled down. Same
        // rationale — wait for .active.
        appState = .inactive
        let auth = makeAuthentication(.saml)

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)

        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 0,
                       "Inactive app must not present the reauth modal")
    }

    // MARK: - Single-flight

    func testRequestReauth_secondCallWhilePresenting_doesNotStackModal() {
        // The mock with completionDelay > 0 simulates a modal that hasn't
        // dismissed yet. Two fast-arriving 401s must produce exactly one
        // present, not two — Adam's logs show /patrons/me/ polls every 30s.
        mockReauthenticator.completionDelay = 5.0
        let auth = makeAuthentication(.saml)

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)
        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)

        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 1,
                       "Single-flight: second request while modal is on screen must be a no-op")
        XCTAssertTrue(coordinator.isPresenting,
                      "isPresenting must remain true until the modal completion fires")
    }

    func testRequestReauth_afterModalDismissed_canPresentAgain() {
        // After the user dismisses (cancels or completes auth), a future
        // 401 — for instance because they cancelled and the next poll
        // 401s again — must be able to re-present.
        mockReauthenticator.completionDelay = 0  // synchronous completion
        let auth = makeAuthentication(.saml)

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)
        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 1)

        // Drain the @MainActor Task that resets isPresenting.
        let drained = expectation(description: "isPresenting reset")
        Task { @MainActor in
            // Two hops: one for the reauthenticator's Task, one for the
            // coordinator's Task that resets the flag.
            await Task.yield()
            await Task.yield()
            drained.fulfill()
        }
        wait(for: [drained], timeout: 1.0)

        XCTAssertFalse(coordinator.isPresenting,
                       "isPresenting must reset after the modal completion fires")

        coordinator.requestReauth(for: userAccount, authDef: auth, triggerURL: nil)
        XCTAssertEqual(mockReauthenticator.authenticateCallCount, 2,
                       "Subsequent 401 after dismissal must be allowed to re-present the modal")
    }

    // MARK: - Helpers

    private func makeAuthentication(_ type: AccountDetails.AuthType) -> AccountDetails.Authentication {
        let dict: [String: Any] = [
            "authType": type.rawValue,
            "authPasscodeLength": 4,
            "patronIDKeyboard": LoginKeyboard.standard.rawValue,
            "pinKeyboard": LoginKeyboard.numeric.rawValue,
            "supportsBarcodeScanner": false,
            "supportsBarcodeDisplay": false
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(AccountDetails.Authentication.self, from: data)
    }
}
