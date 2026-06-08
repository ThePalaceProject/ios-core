//
//  TPPUserAccountTestFactoryTests.swift
//  PalaceTests
//
//  Behavior tests for `TPPUserAccountTestFactory.makeIsolated()`. The factory
//  mints per-call `TPPUserAccount` instances under a unique `libraryUUID`
//  so each test gets keychain-namespaced isolation (each instance writes
//  under `"<storageKey>_test-uuid-<UUID>"`), and a registered resetter
//  clears the residue at `testCaseDidFinish`.
//
//  Per CLAUDE.md TDD: every test below performs Arrange → Act → Assert with
//  a real Act, exercises an isolation invariant, and avoids tautologies.
//

import XCTest
@testable import Palace

final class TPPUserAccountTestFactoryTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The factory writes / reads via TPPKeychain; on hosts lacking the
        // keychain entitlement (some CI runners) we skip — same gate other
        // keychain-dependent tests use.
        try KeychainAvailability.skipIfUnavailable()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
    }

    // MARK: - Invariant 0: resetter registration is order-independent (flake hardening)

    /// `TPPUserAccountIsolationLintTests.testResetterIsRegisteredAfterFactoryUse`
    /// flaked by full-suite order: the resetter used to register fire-once, so
    /// once a predecessor fired it and a later test cleared the registry
    /// (`PalaceTestSetupObservationTests._removeAllForTests()`), a subsequent
    /// mint never re-registered — leaking minted accounts AND failing the lint.
    /// This pins the fix DETERMINISTICALLY (no 35-min full-suite repro needed):
    /// it recreates the exact register → clear → register condition in one test.
    func testMakeIsolated_reRegistersResetter_afterRegistryCleared() {
        // Restore the built-in resetters even if an assertion below fails, so
        // this test (which deliberately clears the registry) can't itself become
        // the polluter it's guarding against.
        defer { _ = PalaceTestSetup.bootstrap() }

        let name = TPPUserAccountTestFactory.resetterName

        // 1. First mint registers the resetter.
        _ = TPPUserAccountTestFactory.makeIsolated(libraryUUID: "order-probe-1")
        XCTAssertTrue(SingletonResetRegistry.shared.registeredNames().contains(name),
                      "First makeIsolated() must register the minted-account resetter")

        // 2. A later test clears the registry — the resetter is dropped.
        SingletonResetRegistry.shared._removeAllForTests()
        XCTAssertFalse(SingletonResetRegistry.shared.registeredNames().contains(name),
                       "Precondition: clearing the registry drops the resetter")

        // 3. A subsequent mint MUST re-register it. Under the old fire-once
        //    registration this stayed false — the root cause of the flake.
        _ = TPPUserAccountTestFactory.makeIsolated(libraryUUID: "order-probe-2")
        XCTAssertTrue(SingletonResetRegistry.shared.registeredNames().contains(name),
                      "makeIsolated() must re-register the resetter after a registry clear — fire-once registration leaks minted accounts and flakes by suite order")
    }

    // MARK: - Invariant 1: each call mints a fresh UUID-namespaced account

    func testMakeIsolated_eachCallReturnsDistinctLibraryUUID() {
        let first = TPPUserAccountTestFactory.makeIsolated()
        let second = TPPUserAccountTestFactory.makeIsolated()

        XCTAssertNotEqual(first.libraryUUID, second.libraryUUID,
                          "Each factory call must mint a distinct libraryUUID so keychain entries don't collide")
        XCTAssertTrue(first.libraryUUID?.hasPrefix("test-uuid-") ?? false,
                      "Factory must namespace minted UUIDs under 'test-uuid-' so they cannot collide with production")
        XCTAssertTrue(second.libraryUUID?.hasPrefix("test-uuid-") ?? false,
                      "Same prefix invariant must hold across calls")
    }

    func testMakeIsolated_honorsExplicitLibraryUUID() {
        let explicit = "test-uuid-explicit-fixture-\(UUID().uuidString)"
        let account = TPPUserAccountTestFactory.makeIsolated(libraryUUID: explicit)

        XCTAssertEqual(account.libraryUUID, explicit,
                       "Explicit libraryUUID must be threaded through to the underlying TPPUserAccount init")
        XCTAssertEqual(account.boundLibraryUUID, explicit,
                       "boundLibraryUUID is the immutable backing reference — must equal libraryUUID")
    }

    // MARK: - Invariant 2: factory does not pollute the AccountsManager shared cache

    func testMakeIsolated_doesNotPolluteSharedCache() {
        let isolated = TPPUserAccountTestFactory.makeIsolated()
        guard let isolatedUUID = isolated.libraryUUID else {
            XCTFail("Factory must produce a non-nil libraryUUID")
            return
        }

        // The shared-cache path returns AccountsManager's cached instance
        // for the same UUID. Because the factory uses init(libraryUUID:)
        // directly, the AccountsManager cache never sees the factory instance.
        let viaCache = TPPUserAccount.sharedAccount(libraryUUID: isolatedUUID)

        XCTAssertFalse(isolated === viaCache,
                       "Factory instance must NOT be the same object as the AccountsManager-cached lookup for the same UUID")
    }

    // MARK: - Invariant 3: the registered resetter clears keychain residue

    func testResetter_clearsKeychainResidue() {
        // Arrange: mint an account, write a barcode (round-trips through keychain).
        let account = TPPUserAccountTestFactory.makeIsolated()
        account.setBarcode("test-barcode-residue", PIN: "0000")
        XCTAssertNotNil(account.barcode,
                        "Pre-condition: setBarcode must round-trip through keychain so we have residue to clear")

        // Act: trigger the resetter the same way the XCTest observer would.
        SingletonResetRegistry.shared.invokeAll()

        // Assert: a freshly-constructed account at the SAME libraryUUID reads
        // nil — meaning the resetter wiped the namespaced keychain key.
        guard let uuid = account.libraryUUID else {
            XCTFail("Factory must produce a libraryUUID")
            return
        }
        let probe = TPPUserAccount(libraryUUID: uuid)
        XCTAssertNil(probe.barcode,
                     "Resetter must have wiped the keychain entry under the factory-minted libraryUUID; a fresh read returns nil")
    }

    // MARK: - Invariant 4: factory never writes under production keychain key

    func testFactory_neverWritesToProductionKeychain() {
        let prodAccountsManager = AppContainer.production().accountsManager
        let prodCurrentId = prodAccountsManager.currentAccountId

        let isolated = TPPUserAccountTestFactory.makeIsolated()
        guard let isolatedUUID = isolated.libraryUUID else {
            XCTFail("Factory must produce a libraryUUID")
            return
        }

        // The factory must never mint a UUID equal to a production library UUID
        // (i.e. tppAccountUUID OR the currentAccountId). Either collision would
        // bypass the per-library keychain-key namespacing.
        XCTAssertNotEqual(isolatedUUID, prodAccountsManager.tppAccountUUID,
                          "Factory UUID must not collide with the production tppAccountUUID — collision would write under the un-namespaced production key")
        if let prodCurrentId = prodCurrentId {
            XCTAssertNotEqual(isolatedUUID, prodCurrentId,
                              "Factory UUID must not collide with the production currentAccountId — collision would write under that library's keychain key")
        }

        // Belt-and-suspenders: the factory's chosen UUID must carry the
        // `test-uuid-` prefix so any future lint can scan keychain keys
        // and flag residue.
        XCTAssertTrue(isolatedUUID.hasPrefix("test-uuid-"),
                      "Factory UUIDs must be prefixed 'test-uuid-' so they are visually distinguishable from production UUIDs (which start with 'urn:uuid:')")
    }

    // MARK: - Invariant 5: registered resetter name is discoverable

    func testFactory_registersResetterUnderStableName() {
        // Touch the factory once to force resetter registration.
        _ = TPPUserAccountTestFactory.makeIsolated()

        let names = SingletonResetRegistry.shared.registeredNames()
        XCTAssertTrue(names.contains("TPPUserAccountTestFactory.minted"),
                      "Factory must register a resetter under the stable name 'TPPUserAccountTestFactory.minted' so the bootstrap and lint can verify it")
    }
}
