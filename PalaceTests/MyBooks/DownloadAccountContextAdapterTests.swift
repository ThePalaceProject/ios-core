//
//  DownloadAccountContextAdapterTests.swift
//  PalaceTests
//
//  Wave 3 S2 — the Downloads-owned account-context seams. Pins:
//    1. `AccountsManagerDownloadContextAdapter` — every provider member returns
//       the right value over a concrete `AccountsManager` (currentAccountID is
//       the DEFAULTS-backed currentAccountId, not currentAccount?.uuid;
//       currentUserAccount()/userAccount(forAccount:) return AccountsManager's
//       per-library instances; auth-surface hosts are empty pre-hydration).
//    2. `TPPUserAccount`'s `DownloadUserAccount` conformance — the exhaustive
//       enum-mapping adapters (`reauthStrategy`, `downloadAuthState`, isSaml,
//       isOidc) map every real case correctly. A mutant that swaps a case or
//       collapses the switch fails at least one row.
//
//  DETERMINISM: `currentAccountId` is controlled through an isolated
//  `UserDefaults` suite (same key the setter writes); no heavy `currentAccount`
//  setter is driven, so no static singletons are touched. Enum mapping is
//  exercised against `TPPUserAccountMock` (keychain-free stored authDefinition /
//  authState), so no keychain, no network, no main-async side effects.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class DownloadAccountContextAdapterTests: PalaceWiringTestCase {

    private var defaults: UserDefaults!
    private var accountsManager: AccountsManager!

    private let accountA = "s2-adapter-A-\(UUID().uuidString)"
    private let accountB = "s2-adapter-B-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = Self.testUserDefaults()
        defaults.set(accountA, forKey: currentAccountIdentifierKey)
        accountsManager = makeFreshAccountsManager(defaults: defaults)
    }

    override func tearDownWithError() throws {
        accountsManager = nil
        defaults = nil
        try super.tearDownWithError()
    }

    private func makeAdapter() -> AccountsManagerDownloadContextAdapter {
        AccountsManagerDownloadContextAdapter(accountsManager: accountsManager)
    }

    // MARK: - DownloadAccountScopeProviding

    /// `currentAccountID` must be the defaults-backed `currentAccountId` — the
    /// exact read BookFileManager funnelled through. Kill case: a mutant that
    /// reads `currentAccount?.uuid` returns nil here (no Account is loaded), so
    /// per-account download scoping would break at cold launch.
    func testCurrentAccountID_isDefaultsBackedCurrentAccountId() {
        let adapter = makeAdapter()
        XCTAssertEqual(adapter.currentAccountID, accountA,
                       "currentAccountID must read the defaults-backed currentAccountId, not a resolved Account uuid")
    }

    /// Flipping the current library (A → B) re-points `currentAccountID`. Pins
    /// the per-account isolation the download-file scoping depends on.
    func testCurrentAccountID_followsAccountSwitch() {
        let adapter = makeAdapter()
        XCTAssertEqual(adapter.currentAccountID, accountA)

        defaults.set(accountB, forKey: currentAccountIdentifierKey)
        XCTAssertEqual(adapter.currentAccountID, accountB,
                       "After the current library flips A→B, currentAccountID must follow")
    }

    /// Pre-hydration (no `Account` object materialized for the current uuid),
    /// the auth-surface hosts are the empty cold-launch signal — consumers must
    /// fall back to legacy behavior rather than false-block. Kill case: a mutant
    /// that force-unwraps `currentAccount` or returns a non-empty default.
    func testAuthSurfaceHosts_emptyWhenNoAccountLoaded() {
        let adapter = makeAdapter()
        XCTAssertTrue(adapter.currentAccountAuthSurfaceHosts.isEmpty,
                      "With no Account loaded, auth-surface hosts must be empty (cold-launch fallback signal)")
    }

    // MARK: - DownloadCredentialsProviding

    /// `currentUserAccount()` must return AccountsManager's current per-library
    /// instance — not a fresh account. Identity matters: the download path reads
    /// and WRITES credentials through it (401 recovery), so it must be the same
    /// instance every other reader sees.
    func testCurrentUserAccount_returnsAccountsManagerCurrentInstance() {
        let adapter = makeAdapter()
        let viaAdapter = adapter.currentUserAccount() as AnyObject
        let direct = accountsManager.currentUserAccount as AnyObject
        XCTAssertTrue(viaAdapter === direct,
                      "currentUserAccount() must return the SAME instance AccountsManager vends")
    }

    /// `userAccount(forAccount:)` must resolve the per-library instance for the
    /// captured uuid (the capture-at-start path for operations that outlive a
    /// switch), identical to `AccountsManager.userAccount(for:)`.
    func testUserAccountForAccount_returnsPerLibraryInstance() {
        let adapter = makeAdapter()
        let viaAdapter = adapter.userAccount(forAccount: accountA) as AnyObject
        let direct = accountsManager.userAccount(for: accountA) as AnyObject
        XCTAssertTrue(viaAdapter === direct,
                      "userAccount(forAccount:) must resolve the same per-library instance as AccountsManager.userAccount(for:)")
    }

    // MARK: - TPPUserAccount: DownloadUserAccount — enum mapping (exhaustive)

    /// `reauthStrategy` must map every real `ReauthStrategy` case correctly, via
    /// the account's `authDefinition`. This is the mirror-enum drift guard
    /// (§5 risk 3): the adapter switch is exhaustive, so a new upstream case is
    /// a compile error; this test pins that each EXISTING case maps right.
    func testReauthStrategyMapping_coversEveryAuthType() throws {
        let cases: [(AccountDetails.AuthType, DownloadReauthStrategy)] = [
            (.saml, .browser),
            (.oidc, .browser),
            (.oauthIntermediary, .tokenRefresh),
            (.token, .tokenRefresh),
            (.basic, .credentialPrompt),
            (.anonymous, .none),
            (.coppa, .none)
        ]
        for (authType, expected) in cases {
            let account: DownloadUserAccount = try makeMockAccount(authType: authType)
            XCTAssertEqual(account.reauthStrategy, expected,
                           "authType \(authType.rawValue) must map to \(expected)")
        }
    }

    /// A nil `authDefinition` (cold launch, before sign-in) must map to `.none`
    /// — matching the download path's `?? .none` reads.
    func testReauthStrategyMapping_nilAuthDefinition_isNone() {
        let account: DownloadUserAccount = TPPUserAccountMock()
        account.markCredentialsStale() // no-op without creds; ensures no authDefinition
        XCTAssertEqual(account.reauthStrategy, .none,
                       "No authDefinition must map to .none, never crash or a wrong strategy")
    }

    /// `isSaml` / `isOidc` must be true for exactly their own auth type and
    /// false for the rest — the download path's `authDefinition?.isSaml == true`
    /// reads reduced onto the protocol.
    func testIsSamlIsOidc_areTypeSpecific() throws {
        let saml: DownloadUserAccount = try makeMockAccount(authType: .saml)
        XCTAssertTrue(saml.isSaml); XCTAssertFalse(saml.isOidc)

        let oidc: DownloadUserAccount = try makeMockAccount(authType: .oidc)
        XCTAssertTrue(oidc.isOidc); XCTAssertFalse(oidc.isSaml)

        let basic: DownloadUserAccount = try makeMockAccount(authType: .basic)
        XCTAssertFalse(basic.isSaml); XCTAssertFalse(basic.isOidc)
    }

    /// `downloadAuthState` must map every `TPPAccountAuthState` case. Exhaustive
    /// switch → compile error on a new case; this pins the existing three.
    func testDownloadAuthStateMapping_coversEveryState() {
        let loggedOut = TPPUserAccountMock()
        loggedOut.setAuthState(.loggedOut)
        XCTAssertEqual((loggedOut as DownloadUserAccount).downloadAuthState, .loggedOut)

        let loggedIn = TPPUserAccountMock()
        loggedIn.setAuthState(.loggedIn)
        XCTAssertEqual((loggedIn as DownloadUserAccount).downloadAuthState, .loggedIn)

        let stale = TPPUserAccountMock()
        stale.setAuthState(.loggedIn)
        stale.markCredentialsStale()
        XCTAssertEqual((stale as DownloadUserAccount).downloadAuthState, .credentialsStale)
    }

    // MARK: - TPPUserAccount: DownloadUserAccount — value pass-through

    /// The identity + credential fields exposed through the protocol existential
    /// must reflect the underlying account. Kill case: a conformance that mapped
    /// the wrong field (e.g. userID→deviceID) would fail here.
    func testIdentityFields_passThroughUnderlyingAccount() {
        let mock = TPPUserAccountMock()
        mock.credentials = .barcodeAndPin(barcode: "patron-barcode", pin: "1234")
        mock.setUserID("user-42")
        mock.setDeviceID("device-99")

        let account: DownloadUserAccount = mock
        XCTAssertEqual(account.barcode, "patron-barcode")
        XCTAssertEqual(account.username, "patron-barcode", "username mirrors barcode")
        XCTAssertEqual(account.PIN, "1234")
        XCTAssertEqual(account.userID, "user-42")
        XCTAssertEqual(account.deviceID, "device-99")
        XCTAssertTrue(account.hasCredentials())
    }

    /// The 401-recovery writeback crosses the capability boundary: writing a
    /// fresh token through the protocol existential must land on the account and
    /// flip its state to loggedIn (mirrors TPPUserAccount.setAuthToken).
    func testSetAuthToken_writesThroughProtocol() {
        let mock = TPPUserAccountMock()
        let account: DownloadUserAccount = mock
        account.setAuthToken("fresh-token", barcode: "b", pin: "p", expirationDate: nil)
        XCTAssertEqual(account.authToken, "fresh-token",
                       "setAuthToken through the DownloadUserAccount surface must persist on the account")
        XCTAssertEqual(account.downloadAuthState, .loggedIn,
                       "A fresh token must flip auth state to loggedIn (clears any stale flag)")
    }

    // MARK: - Helpers

    /// Builds a keychain-free `TPPUserAccountMock` carrying an
    /// `AccountDetails.Authentication` of the requested type (decoded via the
    /// OPDS2 auth-document JSON path — the memberwise init is module-internal).
    private func makeMockAccount(authType: AccountDetails.AuthType) throws -> TPPUserAccountMock {
        let json = """
        { "type": "\(authType.rawValue)", "description": "s2 fixture",
          "labels": {"login": "x", "password": "y"} }
        """
        let docAuth = try JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        let mock = TPPUserAccountMock()
        mock.authDefinition = AccountDetails.Authentication(auth: docAuth)
        return mock
    }
}
