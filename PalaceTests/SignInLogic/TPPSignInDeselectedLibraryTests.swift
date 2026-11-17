//
//  TPPSignInDeselectedLibraryTests.swift
//  PalaceTests
//
//  Settings signs in and out for ANY library, not only the selected one. A
//  library the patron switched away from is pinned at `.detailsEvicted`, so
//  these pin the request and the auth-method selection against that state
//  (PP-5390).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class TPPSignInDeselectedLibraryTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: nil,
            drmAuthorizer: nil
        )
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
    }

    /// The marker a library switch leaves on the library it switched away from.
    private func deselectLibrary() {
        libraryAccountMock.tppAccount._setState(
            .detailsEvicted(.libraryDeselected(uuid: libraryAccountMock.tppAccountUUID))
        )
    }

    /// Business logic bound to a deselected library carrying `document`. The
    /// shared mock is the four-method NYPL fixture; single-method and age-gated
    /// libraries need their own documents.
    private func businessLogic(forDocument document: String) throws -> TPPSignInBusinessLogic {
        let uuid = "urn:uuid:pp5390-\(document)-\(UUID().uuidString)"
        let metadata = OPDS2Publication.Metadata(id: uuid, title: "Deselected \(document)")
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        let account = Account(publication: publication, imageCache: MockImageCache())
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: document, withExtension: "json"))
        account.authenticationDocument = try OPDS2AuthenticationDocument.fromData(try Data(contentsOf: url))
        account._setState(.detailsEvicted(.libraryDeselected(uuid: uuid)))

        let provider = SingleDocumentAccountsProviderMock(account: account)
        return TPPSignInBusinessLogic(
            libraryAccountID: uuid,
            libraryAccountsProvider: provider,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: nil,
            drmAuthorizer: nil
        )
    }

    // MARK: - Where the credentials are posted

    /// A sign-in started from a deselected library's Account page must post to
    /// THAT library's user-profile URL. The request used to come back nil,
    /// because the profile URL was read through the account state machine and
    /// only the selected library is driven to `.detailsLoaded`.
    func testMakeSignInRequest_WhenLibraryIsDeselected_TargetsThatLibrarysProfileURL() throws {
        deselectLibrary()
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        let expectedURL = try XCTUnwrap(libraryAccountMock.tppAccount.details?.userProfileUrl)

        let request = businessLogic.makeRequest(for: .signIn, context: "deselected library sign-in")

        XCTAssertEqual(request?.url?.absoluteString, expectedURL,
                       "Sign-in must post to the user-profile URL of the library the page is bound to.")
    }

    /// Sign-out from the same page has to reach the same library, or a patron
    /// who signs out of a deselected library is signed out only locally.
    func testMakeSignOutRequest_WhenLibraryIsDeselected_TargetsThatLibrarysProfileURL() throws {
        deselectLibrary()
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        let expectedURL = try XCTUnwrap(libraryAccountMock.tppAccount.details?.userProfileUrl)

        let request = businessLogic.makeRequest(for: .signOut, context: "deselected library sign-out")

        XCTAssertEqual(request?.url?.absoluteString, expectedURL,
                       "Sign-out must post to the user-profile URL of the library the page is bound to.")
    }

    /// The fallback is scoped to the eviction marker. While a fetch is in
    /// flight the request must still be refused, so a stale document cannot be
    /// used to post credentials mid-load.
    func testMakeSignInRequest_WhileDetailsAreLoading_IsRefused() {
        libraryAccountMock.tppAccount._setState(.detailsLoading)
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        XCTAssertNil(businessLogic.makeRequest(for: .signIn, context: "loading library sign-in"),
                     "A request must not be built from a document whose fetch is still in flight.")
    }

    // MARK: - Which auth method the tap uses

    /// `logIn()` drops the tap when no auth method is named: it parks on the
    /// readiness gate, which a deselected library never passes. Loading the
    /// page must name one.
    func testSelectPreferredAuthIfNeeded_WhenLibraryIsDeselected_NamesAnAuthMethod() {
        deselectLibrary()
        XCTAssertNil(businessLogic.selectedAuthentication, "Precondition: nothing selected yet")

        businessLogic.selectPreferredAuthIfNeeded()

        XCTAssertNotNil(businessLogic.selectedAuthentication,
                        "A deselected library's page must name an auth method, or the Sign in tap is dropped on the readiness gate.")
    }

    /// The preference order is unchanged: a browser-based method still wins
    /// over the basic-auth fields on a multi-auth library.
    func testSelectPreferredAuthIfNeeded_WhenLibraryIsDeselected_KeepsTheBrowserBasedPreference() {
        deselectLibrary()

        businessLogic.selectPreferredAuthIfNeeded()

        XCTAssertTrue(businessLogic.selectedAuthentication?.isSaml ?? false,
                      "SAML must still be preferred on a multi-auth library — the deselected path must not change which method is chosen.")
    }

    /// The libraries in the report advertise ONE method. Without this the sole
    /// method is never named on a deselected library and the Sign in tap is
    /// dropped — the multi-auth fixture above cannot see it, because a SAML
    /// method is named there whatever the count.
    func testSelectPreferredAuthIfNeeded_WhenASingleAuthLibraryIsDeselected_NamesItsOnlyMethod() throws {
        let logic = try businessLogic(forDocument: "acl_authentication_document")

        logic.selectPreferredAuthIfNeeded()

        XCTAssertEqual(logic.selectedAuthentication?.authType, .basic,
                       "A library advertising one basic method must have it named while deselected.")
    }

    /// An age gate is not a sign-in method. Naming it would put the age-check
    /// row on a deselected library's page, where the picker cannot be presented
    /// and the check answers `false` — which resets that library's downloads
    /// and registry.
    func testSelectPreferredAuthIfNeeded_WhenAnAgeGatedLibraryIsDeselected_NamesNothing() throws {
        let logic = try businessLogic(forDocument: "simplye_authentication_document")

        logic.selectPreferredAuthIfNeeded()

        XCTAssertNil(logic.selectedAuthentication,
                     "An age gate must not be named on a deselected library — the age check cannot be presented there and answering it discards the library's content.")
    }

    /// Whatever the patron already chose wins over the preference.
    func testSelectPreferredAuthIfNeeded_WhenLibraryIsDeselected_DoesNotClobberAChoice() {
        deselectLibrary()
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        businessLogic.selectPreferredAuthIfNeeded()

        XCTAssertEqual(businessLogic.selectedAuthentication?.methodDescription,
                       libraryAccountMock.barcodeAuthentication.methodDescription,
                       "An auth method the patron picked must survive a later call.")
    }
}

/// Serves one account for every UUID, so a test can bind the business logic to
/// a library whose authentication document it chose.
private final class SingleDocumentAccountsProviderMock: NSObject, TPPLibraryAccountsProvider, @unchecked Sendable {
    private let account: Account

    init(account: Account) {
        self.account = account
        super.init()
    }

    var tppAccountUUID: String { account.uuid }
    var currentAccountId: String? { account.uuid }
    var currentAccount: Account? { account }
    func account(_ uuid: String) -> Account? { account }
    func userAccount(for libraryUUID: String) -> TPPUserAccount {
        TPPUserAccountMock.sharedAccount(libraryUUID: libraryUUID)
    }
    var currentUserAccount: TPPUserAccount { userAccount(for: account.uuid) }
}
