//
//  AuthCoordinatorWiringTests.swift
//  PalaceAuthTests
//
//  Round-trip wiring tests for `AuthCoordinator` per CLAUDE.md
//  "State-machine wiring tests must exercise round-trips, not just
//  transitions." The coordinator owns a small piece of internal state
//  (the cooldown timestamp + in-flight task) that the unit tests don't
//  drive through a full lifecycle via the **public seam**.
//
//  These tests drive write → reset → re-enter through
//  `refreshCredentialsIfNeeded` only — they NEVER touch internal state
//  directly. The point is to prove the *wiring* works end-to-end, not
//  just that each transition fires in isolation.
//

import XCTest
@testable import PalaceAuth

final class AuthCoordinatorWiringTests: XCTestCase {

    /// Full lifecycle through the production seam:
    /// 1. logged-in + .ok response → coordinator never called.
    /// 2. observe 401 → call refreshCredentialsIfNeeded → user
    ///    completes modal → success.
    /// 3. observe 401 again → call refreshCredentialsIfNeeded → user
    ///    cancels modal → failure.
    /// 4. observe 401 again WITHIN the cooldown window →
    ///    refreshCredentialsIfNeeded short-circuits to
    ///    `.refreshAlreadyFailed`.
    ///
    /// This proves the cooldown is wired end-to-end via the production
    /// seam, NOT just that the cooldown variable can be poked. Mirrors
    /// the canonical reference pattern in
    /// `AccountsManagerStateMachineWiringTests.Test 7`.
    func testCoordinator_modalSuccess_modalFail_thirdCallShortCircuits() async {
        // First half: configure the modal to succeed.
        let modal = StatefulModal(plan: [.success, .failure])
        let env = WireEnv(mechanism: .saml, modal: modal)

        // Round 1 — modal succeeds.
        let r1 = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        XCTAssertTrue(r1.isSuccess, "expected first call to succeed, got \(r1)")
        XCTAssertEqual(modal.presentCount, 1)

        // Round 2 — modal fails (user cancels).
        let r2 = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        XCTAssertEqual(r2.failureValue, .userCancelled,
            "expected userCancelled on second call, got \(r2)")
        XCTAssertEqual(modal.presentCount, 2)

        // Round 3 — within the cooldown window, should NOT re-present.
        let r3 = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        XCTAssertEqual(r3.failureValue, .refreshAlreadyFailed,
            "expected refreshAlreadyFailed on third call within cooldown, got \(r3)")
        XCTAssertEqual(modal.presentCount, 2,
            "modal must NOT re-present during cooldown")

        // The credentials-stale mark must have fired EXACTLY twice — once
        // per real attempt; the cooldown skip does NOT mark stale again.
        XCTAssertEqual(env.user.markStaleCount, 2,
            "expected exactly 2 markCredentialsStale calls (one per actual refresh attempt)")
    }

    /// Mechanism swap mid-lifecycle: account provider returns SAML on the
    /// first refresh, then Token on the next. The coordinator must
    /// re-resolve the mechanism each call — it must NOT cache the
    /// mechanism across refreshes.
    func testCoordinator_mechanismSwap_betweenRefreshes_redispatches() async {
        let env = WireEnv(mechanism: .saml, modal: StatefulModal(plan: [.success]))
        env.reauth.scriptedSuccess = true

        // Round 1 — SAML → modal.
        let r1 = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        XCTAssertTrue(r1.isSuccess)
        XCTAssertEqual(env.modal.presentCount, 1)
        XCTAssertEqual(env.reauth.silentCount, 0)

        // Mechanism swap (library switch happened).
        env.accountProvider.currentAccountMechanism = .token

        // Round 2 — Token + .expiredToken → silent.
        let r2 = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertTrue(r2.isSuccess)
        XCTAssertEqual(env.modal.presentCount, 1, "modal must NOT fire for token + expiredToken")
        XCTAssertEqual(env.reauth.silentCount, 1, "silent refresh should fire for token mechanism")
    }
}

// MARK: - Wiring environment

private final class WireEnv {
    let coordinator: AuthCoordinator
    let reauth: ScriptedReauthenticator
    let modal: StatefulModal
    let user: WireUserAccount
    let accountProvider: WireAccountProvider

    init(mechanism: AuthMechanism?, modal: StatefulModal) {
        let reauth = ScriptedReauthenticator()
        let user = WireUserAccount()
        let accountProvider = WireAccountProvider(mechanism: mechanism)

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

// MARK: - Scripted spies

private final class StatefulModal: SignInModalPresenting, @unchecked Sendable {
    enum Outcome { case success, failure }
    private let queue = DispatchQueue(label: "StatefulModal")
    private var plan: [Outcome]
    private var _presentCount = 0

    var presentCount: Int { queue.sync { _presentCount } }

    init(plan: [Outcome]) { self.plan = plan }

    func presentSignInModalForCurrentAccount() async -> Bool {
        queue.sync { _presentCount += 1 }
        let outcome: Outcome = queue.sync {
            guard !plan.isEmpty else { return .failure }
            return plan.removeFirst()
        }
        return outcome == .success
    }
}

private final class ScriptedReauthenticator: Reauthenticating, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ScriptedReauth")
    private var _silentCount = 0
    var scriptedSuccess: Bool = false

    var silentCount: Int { queue.sync { _silentCount } }

    func authenticateIfNeeded(usingExistingCredentials: Bool) async -> Bool {
        queue.sync { _silentCount += 1 }
        return scriptedSuccess
    }
}

private final class WireUserAccount: TPPUserAccountReading, TPPUserAccountWriting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "WireUserAccount")
    private var _markStaleCount = 0
    var markStaleCount: Int { queue.sync { _markStaleCount } }

    var hasCredentials: Bool { true }
    var authTokenHasExpired: Bool { false }

    func markCredentialsStale() {
        queue.sync { _markStaleCount += 1 }
    }
}

private final class WireAccountProvider: TPPCurrentLibraryAccountProviding, @unchecked Sendable {
    var currentAccountMechanism: AuthMechanism?

    init(mechanism: AuthMechanism?) {
        self.currentAccountMechanism = mechanism
    }
}

// MARK: - Result helpers (Void Result not Equatable)

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
