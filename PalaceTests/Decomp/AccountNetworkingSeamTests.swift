//  AccountNetworkingSeamTests.swift
//
//  Pins that `AccountsManager` reaches the network executor only through the
//  injected `any AccountNetworking`, which lets it move into `PalaceAccounts`
//  without naming an app-target network type. The account-switch cancel path is
//  covered by `AccountsManagerCurrentAccountSwitchContractTests`; this file adds
//  `clearCache()` routing through the injected executor.

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace

@MainActor
final class AccountNetworkingSeamTests: PalaceWiringTestCase {

    /// Contract: `AccountsManager.clearCache()` clears the network cache through the
    /// injected `AccountNetworking` seam — not by reaching a concrete executor.
    ///
    /// Regression caught: a change that drops the `networkExecutor.clearCache()` call (or
    /// resolves a real executor instead of the injected provider) → the spy never
    /// records `clearCache` → this fails.
    func testClearCache_routesThroughInjectedAccountNetworking() {
        let log = CallLog()
        let spy = RecordingAccountNetworking(log: log)

        let deps = AccountSwitchDependencies(
            imageCache: MockImageCache(),
            accountStateStore: AccountStateStore(),
            resetCoverCircuitBreaker: {},
            networkExecutorProvider: { spy },
            popToRootForAccountSwitch: {}
        )
        let manager = makeFreshAccountsManager(
            defaults: Self.testUserDefaults(),
            borrowReauthResetter: NoopBorrowReauthResetter(),
            switchDependencies: deps
        )

        manager.clearCache()

        XCTAssertTrue(
            log.snapshot().contains { $0.method == "clearCache" },
            "clearCache() must clear the network cache through the injected AccountNetworking seam"
        )
    }

    /// Guards the seam's Sendability/type contract structurally: the provider accepts
    /// a plain (non-`TPPNetworkExecutor`) conformer and `AccountsManager` drives its
    /// cancel path through it. If the property ever reverts to the concrete type, a
    /// plain conformer would no longer satisfy the provider and this file would fail
    /// to compile.
    ///
    /// Regression caught: dropping the `networkExecutor.cancelNonEssentialTasks()` call on the
    /// switch-cleanup path → the spy never records `cancelNonEssentialTasks`.
    func testAccountSwitchCancel_routesThroughInjectedAccountNetworking() {
        let aUUID = "urn:uuid:acctnet-A-\(UUID().uuidString)"
        let bUUID = "urn:uuid:acctnet-B-\(UUID().uuidString)"
        let publication = OPDS2Publication(
            links: [],
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: "AccountNetworking seam",
                id: bUUID,
                title: "AccountNetworking B"
            ),
            images: nil
        )
        let accountB = Account(publication: publication, imageCache: MockImageCache())

        let log = CallLog()
        let spy = RecordingAccountNetworking(log: log)
        let deps = AccountSwitchDependencies(
            imageCache: MockImageCache(),
            accountStateStore: AccountStateStore(),
            resetCoverCircuitBreaker: {},
            networkExecutorProvider: { spy },
            popToRootForAccountSwitch: {}
        )

        let defaults = Self.testUserDefaults()
        defaults.set(aUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(
            defaults: defaults,
            borrowReauthResetter: NoopBorrowReauthResetter(),
            switchDependencies: deps
        )

        manager.currentAccount = accountB

        XCTAssertTrue(
            log.snapshot().contains { $0.method == "cancelNonEssentialTasks" },
            "an account switch must cancel non-essential tasks through the injected AccountNetworking seam"
        )
    }
}

// MARK: - Test doubles

/// Plain `AccountNetworking` recorder — no `TPPNetworkExecutor` inheritance, which is
/// exactly the property the seam guarantees. `@unchecked Sendable`: holds only the
/// thread-safe `CallLog`.
fileprivate final class RecordingAccountNetworking: AccountNetworking, @unchecked Sendable {
    let log: CallLog
    init(log: CallLog) { self.log = log }
    func cancelNonEssentialTasks() { log.record("cancelNonEssentialTasks") }
    func clearCache() { log.record("clearCache") }
    func GET(_ reqURL: URL, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        log.record("GET", args: ["url": reqURL.absoluteString])
        return (Data(), nil)
    }
}

/// Inert `BorrowReauthResetting` for tests that don't assert the borrow-reauth clear.
fileprivate final class NoopBorrowReauthResetter: BorrowReauthResetting, @unchecked Sendable {
    func clearAllBorrowReauthState() {}
}
