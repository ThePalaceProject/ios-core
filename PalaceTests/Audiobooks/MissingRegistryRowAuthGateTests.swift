//
//  MissingRegistryRowAuthGateTests.swift
//  PalaceTests
//
//  PP-5191. Two sibling gates turn "the registry has no row for the selected
//  library" into "this patron is signed out", without consulting the keychain:
//
//      AudiobookSessionManager.isUserAuthenticated()   -> .notAuthenticated
//      CarPlayAuthHelper.isAuthenticated()             -> CarPlay's auth alert
//
//  `currentAccountId` is still set and the credentials are still in the
//  keychain — which is why HelpSpot 19030 reads "It shows that I am logged in"
//  while the app refuses to play a book the patron had just borrowed.
//
//  PP-5135 already applied the correct treatment to the SIBLING arm of the
//  audiobook gate (the `awaitReady()` catch now falls back to stored
//  credentials) and its own comment records that this arm was seen and left
//  failing closed. These tests cover the arm it left.
//
//  Why the fixture is simply "don't populate the registry": the comment above
//  the PP-5135 tests in `AudiobookPositionRestoreTests` records that
//  `currentAccount` CANNOT resolve in this target — the registry store stays
//  empty even after `preloadAccountsFromDiskCacheSync()`. That is exactly the
//  production state PP-5191 describes, so the nil arm is reachable here with no
//  seam at all. On `origin/release/3.3.0` every cell below returns false.
//

import XCTest
@testable import Palace

@MainActor
final class MissingRegistryRowAuthGateTests: XCTestCase {

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
        accountsManager = AccountsManager(defaults: defaults)
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
