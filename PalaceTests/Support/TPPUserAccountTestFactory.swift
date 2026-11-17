//  TPPUserAccountTestFactory.swift
//
//  Mints `TPPUserAccount`s under a UUID-namespaced `libraryUUID`, so keychain
//  keys (`"<storageKey>_test-uuid-<UUID>"`) never collide across tests or with
//  production. `AccountsManager.userAccount(for:)` caches one instance per
//  library, so credential writes in tests used to outlive the test; the factory
//  uses the internal `init(libraryUUID:)` and registers a
//  `SingletonResetRegistry` resetter that calls `removeAll()` on each minted
//  account. No production DEBUG seam or keychain DI is needed.

import Foundation
@testable import Palace

/// Test-only factory for isolated `TPPUserAccount` instances.
///
/// Use `TPPUserAccountTestFactory.makeIsolated()` in any test that previously
/// reached for `TPPUserAccount.sharedAccount(libraryUUID:)`. The whitelist
/// of remaining `sharedAccount` call sites is enforced by
/// `TPPUserAccountIsolationLintTests`.
struct TPPUserAccountTestFactory {

    /// Returns a fresh `TPPUserAccount` bound to a UUID-namespaced
    /// `libraryUUID` (so keychain writes do not collide with production or
    /// with other tests' factory instances).
    ///
    /// - Parameter libraryUUID: An explicit UUID to bind. When `nil`
    ///   (the default), the factory mints `"test-uuid-\(UUID().uuidString)"`.
    ///   Explicit UUIDs are useful for tests that need two factory
    ///   instances to refer to the "same library" (round-trip / cache
    ///   semantics tests).
    /// - Returns: A `TPPUserAccount` whose keychain entries are scoped to
    ///   the minted UUID. The minted UUID is added to a per-process
    ///   tracking list; the registered resetter calls `removeAll()` on
    ///   each tracked instance at `testCaseDidFinish`.
    static func makeIsolated(libraryUUID: String? = nil) -> TPPUserAccount {
        let resolved = libraryUUID ?? "test-uuid-\(UUID().uuidString)"
        let account = TPPUserAccount(libraryUUID: resolved)
        registerResetterIfNeeded()
        Tracker.shared.track(account)
        return account
    }

    // MARK: - Resetter wiring

    /// Name of the resetter this factory registers with `SingletonResetRegistry`.
    static let resetterName = "TPPUserAccountTestFactory.minted"

    /// Registers the minted-account resetter **idempotently on every**
    /// `makeIsolated()` call — register-if-absent, NOT fire-once.
    ///
    /// Why not fire-once: `SingletonResetRegistry` can be cleared mid-suite
    /// (`PalaceTestSetupObservationTests` calls `_removeAllForTests()`, restoring
    /// only the built-ins). A fire-once registration is then permanently lost,
    /// so later minted accounts leak (no `removeAll()` at `testCaseDidFinish`)
    /// and `TPPUserAccountIsolationLintTests.testResetterIsRegisteredAfterFactoryUse`
    /// flakes depending on full-suite order. Re-registering when absent makes
    /// every mint self-healing and order-independent. The registry allows
    /// duplicate registration (overwrites in-place); the `contains` guard keeps
    /// the registered-names diagnostic clean (no redundant churn).
    private static func registerResetterIfNeeded() {
        guard !SingletonResetRegistry.shared.registeredNames().contains(resetterName) else { return }
        SingletonResetRegistry.shared.register(resetterName) {
            Tracker.shared.resetAll()
        }
    }

    /// Process-wide tracker of accounts minted by the factory. The list
    /// is the source of truth for the resetter: when `testCaseDidFinish`
    /// fires, every tracked account is sent `removeAll()` (which zeroes
    /// the keychain entries under its namespaced libraryUUID) and the
    /// list is cleared.
    ///
    /// Per `SingletonResetRegistry` contract, the resetter MUST run in
    /// < 10 ms on the main thread. `removeAll()` is keychain-bound, so we
    /// keep the tracked list short (one entry per test). Lock is held
    /// only across array snapshot — closures run outside the lock.
    /// `@unchecked Sendable`: the only mutable stored state (`minted`) is
    /// guarded by `lock` — both `track` and `resetAll` acquire it before
    /// touching the array. The compiler can't see the lock, but the type
    /// guarantees it, so `static let shared` is safe across concurrency domains.
    private final class Tracker: @unchecked Sendable {
        static let shared = Tracker()

        private let lock = NSLock()
        private var minted: [TPPUserAccount] = []

        private init() {}

        func track(_ account: TPPUserAccount) {
            lock.lock()
            defer { lock.unlock() }
            minted.append(account)
        }

        func resetAll() {
            lock.lock()
            let snapshot = minted
            minted.removeAll()
            lock.unlock()
            for account in snapshot {
                account.removeAll()
            }
        }
    }
}
