//  MissingRegistryRowAuthGateTests.swift
//
//  PP-5191: `AudiobookSessionManager.isUserAuthenticated()` and
//  `CarPlayAuthHelper.isAuthenticated()` treated a missing registry row for the
//  selected library as signed out, although the credentials were still in the
//  keychain (HelpSpot 19030). PP-5135 fixed the sibling `awaitReady()` catch arm;
//  these tests cover the nil-account arm. No seam is needed: `currentAccount`
//  cannot resolve in this test target, which is the production state PP-5191 hits.

import XCTest
@testable import Palace

// `PalaceWiringTestCase`, not `XCTestCase`: this suite mints an `AccountsManager`,
// so it needs the base's tearDown cancel + boundary main-hop flush or its background
// work outlives the test and bleeds into the next one. Enforced by
// `AccountsManagerIsolationLintTests` and `TearDownRequiredLintTests`.
final class MissingRegistryRowAuthGateTests: PalaceWiringTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var libraryUUID: String!
    private var accountsManager: AccountsManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Both gates answer from the keychain once the fix lands, so a
        // simulator without keychain access would make every assertion below
        // vacuous rather than failing. Skip loudly instead.
        try KeychainAvailability.skipIfUnavailable()

        libraryUUID = "urn:uuid:\(UUID().uuidString)"
        suiteName = "PP5191-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // The selected library is KNOWN — this is the whole point. Only the
        // registry ROW is missing.
        defaults.set(libraryUUID, forKey: currentAccountIdentifierKey)
        // `makeFreshAccountsManager` — not a bare `AccountsManager(...)`. It pins the
        // `loadCatalogs` opt-out and registers the manager for tearDown cancellation.
        accountsManager = makeFreshAccountsManager(defaults: defaults)
    }

    override func tearDownWithError() throws {
        accountsManager.userAccount(for: libraryUUID).removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        accountsManager = nil
        defaults = nil
        try super.tearDownWithError()
    }

    /// Guards the premise every assertion below depends on. If the registry
    /// ever starts resolving in this target, these tests stop exercising the
    /// nil arm and would pass for the wrong reason.
    func testPremise_currentAccountIsNilWhileCurrentAccountIdIsSet() {
        XCTAssertEqual(accountsManager.currentAccountId, libraryUUID,
                       "The selected library must be known — the defect is a missing ROW, not a missing selection")
        XCTAssertNil(accountsManager.currentAccount,
                     "Premise of this suite: the registry has no row for the selected library")
    }

    // MARK: - AudiobookSessionManager.isUserAuthenticated()

    func testAudiobookGate_whenRegistryRowMissingAndCredentialsStored_reportsAuthenticated() async {
        accountsManager.userAccount(for: libraryUUID).setBarcode("pp5191-barcode", PIN: "pp5191-pin")
        let sut = AudiobookSessionManager(appContainer: makeTestAppContainer(accountsManager: accountsManager))

        let authenticated = await sut.isUserAuthenticated()

        XCTAssertTrue(authenticated,
                      "A signed-in patron whose library is missing from the registry must not be told to sign in — the keychain, not the registry, answers 'is this patron signed in'")
    }

    func testAudiobookGate_whenRegistryRowMissingAndNoCredentials_reportsNotAuthenticated() async {
        let sut = AudiobookSessionManager(appContainer: makeTestAppContainer(accountsManager: accountsManager))

        let authenticated = await sut.isUserAuthenticated()

        XCTAssertFalse(authenticated,
                       "A genuinely signed-out patron must still be refused — the fallback reads credentials, it does not assume them")
    }

    // MARK: - CarPlayAuthHelper.isAuthenticated()

    func testCarPlayGate_whenRegistryRowMissingAndCredentialsStored_reportsAuthenticated() async {
        accountsManager.userAccount(for: libraryUUID).setBarcode("pp5191-barcode", PIN: "pp5191-pin")

        let authenticated = await CarPlayAuthHelper.isAuthenticated(accountsManager: accountsManager)

        XCTAssertTrue(authenticated,
                      "CarPlay cannot present a sign-in UI, so failing closed here strands a signed-in patron with no recovery on the head unit")
    }

    func testCarPlayGate_whenRegistryRowMissingAndNoCredentials_reportsNotAuthenticated() async {
        let authenticated = await CarPlayAuthHelper.isAuthenticated(accountsManager: accountsManager)

        XCTAssertFalse(authenticated,
                       "No credentials still means not authenticated on CarPlay")
    }
}
