//
//  SpyAuthCoordinator.swift
//  PalaceTests
//
//  Spy collaborator suite for testing call sites that route 401/403 through
//  PalaceAuth's `AuthCoordinator`. The spies record what was asked of them
//  and let the production AuthCoordinator be constructed against test-only
//  collaborators so each migrated caller can be asserted in isolation.
//
//  swarm_66819d80 Module C — caller migration test infrastructure.
//

import Foundation
@testable import PalaceAuth

// MARK: - SpyCoordinatorReauthenticator

/// Spy `Reauthenticating` — records every `authenticateIfNeeded` call and
/// returns a configurable result.
final class SpyCoordinatorReauthenticator: Reauthenticating, @unchecked Sendable {

    /// Stubbed result that `authenticateIfNeeded` returns. Default: `true`
    /// (silent refresh succeeded). Tests set this to `false` to drive the
    /// modal-fallback path.
    var stubbedResult: Bool = true

    private(set) var calls: [(usingExistingCredentials: Bool, timestamp: Date)] = []
    private let lock = NSLock()

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }

    func authenticateIfNeeded(usingExistingCredentials: Bool) async -> Bool {
        lock.lock()
        calls.append((usingExistingCredentials, Date()))
        let result = stubbedResult
        lock.unlock()
        return result
    }
}

// MARK: - SpyCoordinatorModalPresenter

/// Spy `SignInModalPresenting` — records every modal-present call and
/// returns a configurable success/cancel result.
final class SpyCoordinatorModalPresenter: SignInModalPresenting, @unchecked Sendable {

    /// Stubbed result. Default: `false` (user cancelled) so tests
    /// explicitly opt in to the success path.
    var stubbedResult: Bool = false

    private(set) var presentCallCount: Int = 0
    private let lock = NSLock()

    func presentSignInModalForCurrentAccount() async -> Bool {
        lock.lock()
        presentCallCount += 1
        let result = stubbedResult
        lock.unlock()
        return result
    }
}

// MARK: - SpyCoordinatorUserAccount

/// Spy `TPPUserAccountReading & TPPUserAccountWriting` — exposes mutable
/// `hasCredentials` / `authTokenHasExpired` so each test can stage the
/// pre-state and assert post-state side effects (markCredentialsStale
/// call count).
final class SpyCoordinatorUserAccount: TPPUserAccountReading, TPPUserAccountWriting, @unchecked Sendable {

    var hasCredentials: Bool = true
    var authTokenHasExpired: Bool = false

    private(set) var markCredentialsStaleCallCount: Int = 0
    private let lock = NSLock()

    func markCredentialsStale() {
        lock.lock()
        markCredentialsStaleCallCount += 1
        lock.unlock()
    }
}

// MARK: - SpyCoordinatorAccountProvider

/// Spy `TPPCurrentLibraryAccountProviding` — stub the current library's
/// mechanism. Tests set `stubbedMechanism` to drive the dispatch table.
final class SpyCoordinatorAccountProvider: TPPCurrentLibraryAccountProviding, @unchecked Sendable {

    var stubbedMechanism: AuthMechanism? = .token

    var currentAccountMechanism: AuthMechanism? { stubbedMechanism }
}

// MARK: - Factory

/// Convenience factory that wires the four spy collaborators into a real
/// `AuthCoordinator`. Tests use this to drive the actual coordinator
/// surface (single-flight + cooldown + dispatch matrix) against
/// recordable spies for each migrated caller assertion.
enum SpyAuthCoordinatorFactory {
    /// Returns a tuple of (coordinator, reauthenticator spy, modal spy,
    /// user-account spy, account-provider spy) so tests can stage stubs
    /// + assert calls.
    static func make(
        mechanism: AuthMechanism = .token,
        stubReauthResult: Bool = true,
        stubModalResult: Bool = false,
        hasCredentials: Bool = true
    ) -> (
        coordinator: AuthCoordinator,
        reauth: SpyCoordinatorReauthenticator,
        modal: SpyCoordinatorModalPresenter,
        userAccount: SpyCoordinatorUserAccount,
        accountProvider: SpyCoordinatorAccountProvider
    ) {
        let reauth = SpyCoordinatorReauthenticator()
        reauth.stubbedResult = stubReauthResult

        let modal = SpyCoordinatorModalPresenter()
        modal.stubbedResult = stubModalResult

        let userAccount = SpyCoordinatorUserAccount()
        userAccount.hasCredentials = hasCredentials

        let accountProvider = SpyCoordinatorAccountProvider()
        accountProvider.stubbedMechanism = mechanism

        let coordinator = AuthCoordinator(
            reauthenticator: reauth,
            modalPresenter: modal,
            userAccount: userAccount,
            accountProvider: accountProvider
        )

        return (coordinator, reauth, modal, userAccount, accountProvider)
    }
}
