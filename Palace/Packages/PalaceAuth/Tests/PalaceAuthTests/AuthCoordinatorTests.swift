//
//  AuthCoordinatorTests.swift
//  PalaceAuthTests
//
//  Spy-based behavior tests for `AuthCoordinator`. Verifies the
//  dispatch table from the contract, single-flight semantics, and the
//  short-cooldown after a failed refresh.
//

import XCTest
@testable import PalaceAuth

final class AuthCoordinatorTests: XCTestCase {

    // MARK: - Per-IdP routing (one test per interesting (mechanism, reason) cell)

    func testRefresh_OAuthIntermediary_ExpiredToken_PresentsModal() async {
        let env = TestEnv(mechanism: .oauthIntermediary, modalSucceeds: true)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertTrue(result.isSuccess, "expected .success but got \(result)")
        XCTAssertEqual(env.modal.presentCount, 1)
        XCTAssertEqual(env.reauth.silentCount, 0)
    }

    func testRefresh_SamlReason_ForcesModalEvenIfReauthenticatorAvailable() async {
        let env = TestEnv(mechanism: .saml, modalSucceeds: true)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        XCTAssertTrue(result.isSuccess, "expected .success but got \(result)")
        XCTAssertEqual(env.modal.presentCount, 1)
        XCTAssertEqual(env.reauth.silentCount, 0)
    }

    func testRefresh_OidcReason_ForcesModalBecauseNoClientSideRefresh() async {
        let env = TestEnv(mechanism: .oidc, modalSucceeds: true)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .oidcRefreshFailed)
        XCTAssertTrue(result.isSuccess, "expected .success but got \(result)")
        XCTAssertEqual(env.modal.presentCount, 1)
        XCTAssertEqual(env.reauth.silentCount, 0)
    }

    func testRefresh_Token_ExpiredToken_AttemptsSilentRefreshFirst() async {
        let env = TestEnv(mechanism: .token, silentSucceeds: true)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertTrue(result.isSuccess, "expected .success but got \(result)")
        XCTAssertEqual(env.reauth.silentCount, 1)
        XCTAssertEqual(env.modal.presentCount, 0)
    }

    func testRefresh_Basic_ExpiredToken_AttemptsSilentRefreshFirst() async {
        let env = TestEnv(mechanism: .basic, silentSucceeds: true)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertTrue(result.isSuccess, "expected .success but got \(result)")
        XCTAssertEqual(env.reauth.silentCount, 1)
        XCTAssertEqual(env.modal.presentCount, 0)
    }

    func testRefresh_Token_SilentRefreshFails_FallsBackToModal() async {
        let env = TestEnv(mechanism: .token, silentSucceeds: false, modalSucceeds: true)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertTrue(result.isSuccess, "expected .success but got \(result)")
        XCTAssertEqual(env.reauth.silentCount, 1)
        XCTAssertEqual(env.modal.presentCount, 1)
    }

    func testRefresh_Token_InvalidCredentials_GoesDirectToModal() async {
        let env = TestEnv(mechanism: .token, modalSucceeds: true)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .invalidCredentials)
        XCTAssertTrue(result.isSuccess, "expected .success but got \(result)")
        XCTAssertEqual(env.reauth.silentCount, 0,
            "invalidCredentials must skip silent refresh — the credentials are bad")
        XCTAssertEqual(env.modal.presentCount, 1)
    }

    func testRefresh_Basic_Unknown401_GoesDirectToModal() async {
        let env = TestEnv(mechanism: .basic, modalSucceeds: true)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .unknown401)
        XCTAssertTrue(result.isSuccess, "expected .success but got \(result)")
        XCTAssertEqual(env.reauth.silentCount, 0)
        XCTAssertEqual(env.modal.presentCount, 1)
    }

    func testRefresh_Saml_ExpiredToken_StillForcesModal() async {
        // SAML routes to modal regardless of reason — even if the
        // classifier mistakenly returned .expiredToken instead of
        // .samlSessionExpired, we must NOT attempt a silent token refresh.
        let env = TestEnv(mechanism: .saml, modalSucceeds: true)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertTrue(result.isSuccess, "expected .success but got \(result)")
        XCTAssertEqual(env.modal.presentCount, 1)
        XCTAssertEqual(env.reauth.silentCount, 0)
    }

    func testRefresh_Oidc_ExpiredToken_StillForcesModal() async {
        let env = TestEnv(mechanism: .oidc, modalSucceeds: true)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertTrue(result.isSuccess, "expected .success but got \(result)")
        XCTAssertEqual(env.modal.presentCount, 1)
        XCTAssertEqual(env.reauth.silentCount, 0)
    }

    // MARK: - User cancellation

    func testRefresh_UserCancels_Modal_ReturnsUserCancelled() async {
        let env = TestEnv(mechanism: .saml, modalSucceeds: false)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        XCTAssertEqual(result.failureValue, .userCancelled, "expected userCancelled, got \(result)")
        XCTAssertEqual(env.modal.presentCount, 1)
    }

    func testRefresh_UserCancelsModal_AfterSilentFails_ReturnsUserCancelled() async {
        let env = TestEnv(mechanism: .token, silentSucceeds: false, modalSucceeds: false)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertEqual(result.failureValue, .userCancelled, "expected userCancelled, got \(result)")
        XCTAssertEqual(env.reauth.silentCount, 1)
        XCTAssertEqual(env.modal.presentCount, 1)
    }

    // MARK: - No active account

    func testRefresh_NoActiveAccount_ReturnsNoActiveAccount() async {
        let env = TestEnv(mechanism: nil)
        let result = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertEqual(result.failureValue, .noActiveAccount, "expected noActiveAccount, got \(result)")
        XCTAssertEqual(env.modal.presentCount, 0)
        XCTAssertEqual(env.reauth.silentCount, 0)
        XCTAssertEqual(env.user.markStaleCount, 0,
            "no active account → coordinator must not even touch credential state")
    }

    // MARK: - Cooldown (refresh-already-failed)

    func testRefresh_RefreshAlreadyFailed_DoesNotRetryWithinWindow() async {
        let env = TestEnv(mechanism: .saml, modalSucceeds: false)
        let first = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        XCTAssertEqual(first.failureValue, .userCancelled, "expected userCancelled, got \(first)")

        let second = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        XCTAssertEqual(second.failureValue, .refreshAlreadyFailed,
            "second call inside cooldown must short-circuit, not re-present modal")
        XCTAssertEqual(env.modal.presentCount, 1,
            "modal must NOT re-present during cooldown")
    }

    func testRefresh_AfterSuccessClearsCooldown() async {
        // First fails, second after reset succeeds — proves the cooldown
        // is keyed on failure, not on every call.
        let env = TestEnv(mechanism: .saml, modalSucceeds: true)
        let first = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        XCTAssertTrue(first.isSuccess, "expected success, got \(first)")

        // Second call after success must NOT short-circuit.
        let second = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        XCTAssertTrue(second.isSuccess, "expected success, got \(second)")
        XCTAssertEqual(env.modal.presentCount, 2,
            "successful refresh must NOT poison subsequent calls")
    }

    // MARK: - Single-flight

    func testRefresh_SingleFlight_CallerArrivingDuringFlight_JoinsIt() async {
        // The gate holds the first silent refresh open, and the test waits
        // until the second caller has joined before releasing it. Firing two
        // `async let` calls against a stub that returns immediately does not
        // guarantee overlap: under load the first flight can finish before
        // the second caller arrives.
        let gate = RefreshGate()
        let env = TestEnv(mechanism: .token, silentSucceeds: true, silentGate: gate)

        let (a, b, joined) = await refreshWithSecondCallerJoiningFirst(env.coordinator, gate: gate)

        XCTAssertTrue(joined, "second caller never joined the in-flight refresh")
        XCTAssertTrue(a.isSuccess, "first call expected success, got \(a)")
        XCTAssertTrue(b.isSuccess, "second call expected success, got \(b)")
        XCTAssertEqual(env.reauth.silentCount, 1,
            "a caller arriving during a refresh must join it, not start another")
    }

    func testRefresh_SingleFlight_CallerArrivingAfterFlightCompletes_StartsNewFlight() async {
        // The complement: once a refresh has completed, the slot is clear and
        // the next caller refreshes again. A slot that is never cleared would
        // hand every later caller a stale outcome.
        let env = TestEnv(mechanism: .token, silentSucceeds: true)

        let a = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        let b = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)

        XCTAssertTrue(a.isSuccess, "first call expected success, got \(a)")
        XCTAssertTrue(b.isSuccess, "second call expected success, got \(b)")
        XCTAssertEqual(env.reauth.silentCount, 2,
            "a caller arriving after a refresh completed must start a new one")
        let joins = await env.coordinator.joinedInFlightRefreshCount
        XCTAssertEqual(joins, 0, "no refresh was in flight to join")
    }

    // MARK: - markCredentialsStale wiring

    func testRefresh_MarksCredentialsStale_BeforeAttemptingRefresh() async {
        let env = TestEnv(mechanism: .token, silentSucceeds: true)
        XCTAssertEqual(env.user.markStaleCount, 0)
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertEqual(env.user.markStaleCount, 1,
            "coordinator must mark credentials stale so other consumers gate on the refresh")
    }

    // MARK: - signOut

    func testSignOut_CallsMarkCredentialsStale_AndSurfacesNoModal() async {
        let env = TestEnv(mechanism: .saml)
        await env.coordinator.signOut()
        XCTAssertEqual(env.user.markStaleCount, 1)
        XCTAssertEqual(env.modal.presentCount, 0,
            "sign-out must NOT trigger a re-auth modal")
        XCTAssertEqual(env.reauth.silentCount, 0,
            "sign-out must NOT trigger a silent refresh")
    }

    // MARK: - Route table (covers dispatch matrix purely)

    func testRoute_SamlAlwaysModal() {
        for reason: ReauthReason in [.expiredToken, .invalidCredentials, .samlSessionExpired, .oidcRefreshFailed, .unknown401] {
            XCTAssertEqual(AuthCoordinator.route(reason: reason, mechanism: .saml), .modal,
                "SAML must route to modal for reason \(reason)")
        }
    }

    func testRoute_OidcAlwaysModal() {
        for reason: ReauthReason in [.expiredToken, .invalidCredentials, .samlSessionExpired, .oidcRefreshFailed, .unknown401] {
            XCTAssertEqual(AuthCoordinator.route(reason: reason, mechanism: .oidc), .modal,
                "OIDC must route to modal for reason \(reason)")
        }
    }

    func testRoute_OAuthIntermediaryAlwaysModal() {
        for reason: ReauthReason in [.expiredToken, .invalidCredentials, .samlSessionExpired, .oidcRefreshFailed, .unknown401] {
            XCTAssertEqual(AuthCoordinator.route(reason: reason, mechanism: .oauthIntermediary), .modal,
                "OAuth-intermediary must route to modal for reason \(reason)")
        }
    }

    func testRoute_TokenExpiredTokenSilent_OthersModal() {
        XCTAssertEqual(AuthCoordinator.route(reason: .expiredToken, mechanism: .token), .silentRefresh)
        XCTAssertEqual(AuthCoordinator.route(reason: .invalidCredentials, mechanism: .token), .modal)
        XCTAssertEqual(AuthCoordinator.route(reason: .unknown401, mechanism: .token), .modal)
    }

    func testRoute_BasicExpiredTokenSilent_OthersModal() {
        XCTAssertEqual(AuthCoordinator.route(reason: .expiredToken, mechanism: .basic), .silentRefresh)
        XCTAssertEqual(AuthCoordinator.route(reason: .invalidCredentials, mechanism: .basic), .modal)
        XCTAssertEqual(AuthCoordinator.route(reason: .unknown401, mechanism: .basic), .modal)
    }
}

// MARK: - Test environment

private struct TestEnv {
    let coordinator: AuthCoordinator
    let reauth: SpyReauthenticator
    let modal: SpyModalPresenter
    let user: SpyUserAccount
    let accountProvider: SpyAccountProvider

    init(
        mechanism: AuthMechanism?,
        silentSucceeds: Bool = false,
        modalSucceeds: Bool = false,
        silentGate: RefreshGate? = nil
    ) {
        let reauth = SpyReauthenticator(succeeds: silentSucceeds, gate: silentGate)
        let modal = SpyModalPresenter(succeeds: modalSucceeds)
        let user = SpyUserAccount()
        let accountProvider = SpyAccountProvider(mechanism: mechanism)

        self.reauth = reauth
        self.modal = modal
        self.user = user
        self.accountProvider = accountProvider
        self.coordinator = AuthCoordinator(
            reauthenticator: reauth,
            modalPresenter: modal,
            userAccount: user,
            accountProvider: accountProvider
        )
    }
}

// MARK: - Spies
// Spies are minimal — they record call counts and return stubbed
// outcomes. Behavior assertions live in the tests, never in the spy.

private final class SpyReauthenticator: Reauthenticating, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpyReauthenticator")
    private var _silentCount = 0
    private let succeeds: Bool
    private let gate: RefreshGate?

    var silentCount: Int { queue.sync { _silentCount } }

    init(succeeds: Bool, gate: RefreshGate? = nil) {
        self.succeeds = succeeds
        self.gate = gate
    }

    func authenticateIfNeeded(usingExistingCredentials: Bool) async -> Bool {
        queue.sync { _silentCount += 1 }
        await gate?.enterAndWait()
        return succeeds
    }
}

private final class SpyModalPresenter: SignInModalPresenting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpyModalPresenter")
    private var _presentCount = 0
    private let succeeds: Bool

    var presentCount: Int { queue.sync { _presentCount } }

    init(succeeds: Bool) { self.succeeds = succeeds }

    func presentSignInModalForCurrentAccount() async -> Bool {
        queue.sync { _presentCount += 1 }
        return succeeds
    }
}

private final class SpyUserAccount: TPPUserAccountReading, TPPUserAccountWriting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpyUserAccount")
    private var _markStaleCount = 0

    var markStaleCount: Int { queue.sync { _markStaleCount } }

    var hasCredentials: Bool { true }
    var authTokenHasExpired: Bool { false }

    func markCredentialsStale() {
        queue.sync { _markStaleCount += 1 }
    }
}

private final class SpyAccountProvider: TPPCurrentLibraryAccountProviding, @unchecked Sendable {
    var currentAccountMechanism: AuthMechanism?

    init(mechanism: AuthMechanism?) {
        self.currentAccountMechanism = mechanism
    }
}

// MARK: - Result helpers for Result<Void, _> (Void isn't Equatable, so we
// can't XCTAssertEqual on the Result directly).

private extension Result where Success == Void {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var failureValue: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}
