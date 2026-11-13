//
//  AccountDetailDeselectedLibraryTests.swift
//  PalaceTests
//
//  The Account page reached from Settings → Libraries signs in to the library
//  the patron tapped, which is not always the selected one. A deselected
//  library's state machine is pinned at `.detailsEvicted`, so these pin the
//  sign-in form and the sign-in request against that state (PP-5390).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountDetailDeselectedLibraryTests: PalaceTestCase {

    /// An account carrying a parsed authentication document, the way `details`
    /// is populated once the Account page has loaded the document for the
    /// library it is bound to. `acl` advertises one basic auth — the shape of
    /// the libraries in the report; `simplye` advertises a COPPA gate only, so
    /// it collects no credentials.
    private func accountWithParsedAuthDocument(uuid: String, fixture: String) throws -> Account {
        let metadata = OPDS2Publication.Metadata(id: uuid, title: "Deselected Library")
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        let account = Account(publication: publication, imageCache: MockImageCache())
        let docURL = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: fixture, withExtension: "json"))
        account.authenticationDocument = try OPDS2AuthenticationDocument
            .fromData(try Data(contentsOf: docURL))
        return account
    }

    /// A library advertising two credential methods and no browser-based one,
    /// so nothing is named for it. No bundled fixture has this shape.
    private func accountWithTwoBasicMethods(uuid: String) throws -> Account {
        let json = """
        {
          "id": "\(uuid)",
          "title": "Two Methods Library",
          "links": [
            {"href": "https://example.com/patrons/me/", "type": "vnd.librarysimplified/user-profile+json",
             "rel": "http://librarysimplified.org/terms/rel/user-profile"}
          ],
          "authentication": [
            {"type": "http://opds-spec.org/auth/basic", "description": "Library Barcode",
             "labels": {"login": "Barcode", "password": "PIN"},
             "inputs": {"login": {"keyboard": "Number pad"}, "password": {"keyboard": "Number pad"}}},
            {"type": "http://opds-spec.org/auth/basic", "description": "Staff Login",
             "labels": {"login": "Username", "password": "Password"},
             "inputs": {"login": {"keyboard": "Default"}, "password": {"keyboard": "Default"}}}
          ]
        }
        """
        let metadata = OPDS2Publication.Metadata(id: uuid, title: "Two Methods Library")
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        let account = Account(publication: publication, imageCache: MockImageCache())
        account.authenticationDocument = try OPDS2AuthenticationDocument
            .fromData(try XCTUnwrap(json.data(using: .utf8)))
        return account
    }

    private var signedOutSnapshot: TPPUserAccount.CredentialSnapshot {
        TPPUserAccount.CredentialSnapshot(
            hasCredentials: false,
            hasAuthToken: false,
            authState: .loggedOut,
            barcode: nil,
            pin: nil,
            authToken: nil,
            authDefinition: nil,
            cookies: nil
        )
    }

    private func signedInSnapshot(barcode: String = "01230000000237") -> TPPUserAccount.CredentialSnapshot {
        TPPUserAccount.CredentialSnapshot(
            hasCredentials: true,
            hasAuthToken: false,
            authState: .loggedIn,
            barcode: barcode,
            pin: "1234",
            authToken: nil,
            authDefinition: nil,
            cookies: nil
        )
    }

    private func makeViewModel(
        libraryAccountID: String,
        appContainer: AppContainer,
        snapshot: TPPUserAccount.CredentialSnapshot? = nil
    ) -> AccountDetailViewModel {
        let credentials = snapshot ?? signedOutSnapshot
        return AccountDetailViewModel(
            libraryAccountID: libraryAccountID,
            accountsManager: appContainer.accountsManager,
            bookRegistry: appContainer.bookRegistry,
            downloadCenter: appContainer.downloadCenter,
            settings: appContainer.settings,
            userAccountPublisher: appContainer.userAccountPublisher,
            drmAuthorizerProvider: { nil },
            credentialSnapshotProvider: { _ in credentials }
        )
    }

    /// Yield until the view model's init Task has run `setupTableData()`.
    private func drainMainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func cells(_ viewModel: AccountDetailViewModel) -> [CellType] {
        viewModel.tableData.flatMap { $0 }
    }

    // MARK: - The sign-in form

    /// A patron who is signed out of a library they switched away from must
    /// still get that library's credential fields and Sign in button. The form
    /// used to be gated on `TPPUserAccount.needsAuth`, which is derived from
    /// the auth definition stored at sign-in and is therefore false for every
    /// library the patron has not signed into yet.
    func testAccountPage_WhenLibraryIsDeselectedAndSignedOut_OffersTheSignInForm() async throws {
        let appContainer = makeTestAppContainer()
        let uuid = "urn:uuid:pp5390-deselected-\(UUID().uuidString)"
        let account = try accountWithParsedAuthDocument(uuid: uuid, fixture: "acl_authentication_document")
        let restore = appContainer.accountsManager._seedAccountForTesting(account)
        defer { restore() }
        // The marker a library switch leaves on the library it switched away
        // from: the document has parsed, but nothing drives this account to
        // `.detailsLoaded` while it is not the selected library.
        account._setState(.detailsEvicted(.libraryDeselected(uuid: uuid)))

        let viewModel = makeViewModel(libraryAccountID: uuid, appContainer: appContainer)
        await drainMainActor()

        let rendered = cells(viewModel)
        XCTAssertTrue(rendered.contains(.barcode),
                      "A deselected library's page must offer the library-card field — without it a patron with two libraries cannot sign in to the second one.")
        XCTAssertTrue(rendered.contains(.logInSignOut),
                      "A deselected library's page must offer the Sign in button.")
    }

    /// Signing out ON a deselected library's page must leave the form in place.
    /// Sign-out clears the stored auth definition, which is what used to
    /// collapse the page to a stub with no way back in.
    func testAccountPage_WhenSignedOutWhileDeselected_KeepsTheSignInForm() async throws {
        let appContainer = makeTestAppContainer()
        let uuid = "urn:uuid:pp5390-signout-\(UUID().uuidString)"
        let account = try accountWithParsedAuthDocument(uuid: uuid, fixture: "acl_authentication_document")
        let restore = appContainer.accountsManager._seedAccountForTesting(account)
        defer { restore() }
        account._setState(.detailsEvicted(.libraryDeselected(uuid: uuid)))

        let viewModel = makeViewModel(libraryAccountID: uuid, appContainer: appContainer)
        await drainMainActor()

        // `removeAll()` posts this synchronously at the end of sign-out.
        NotificationCenter.default.post(name: .TPPDidSignOut, object: nil)
        await drainMainActor()

        XCTAssertTrue(cells(viewModel).contains(.barcode),
                      "After a sign-out on a deselected library the page must still offer the sign-in form, not collapse to Report an Issue.")
    }

    /// A multi-auth library offers its methods for the patron to choose from.
    /// Without the chooser the page shows only whichever method the app
    /// preferred, so a patron who needs the card fields on a library that also
    /// advertises SAML has no way to reach them.
    func testAccountPage_WhenMultiAuthLibraryIsDeselected_OffersTheAuthMethodChoice() async throws {
        let appContainer = makeTestAppContainer()
        let uuid = "urn:uuid:pp5390-multiauth-\(UUID().uuidString)"
        let account = try accountWithParsedAuthDocument(uuid: uuid, fixture: "nypl_authentication_document")
        let restore = appContainer.accountsManager._seedAccountForTesting(account)
        defer { restore() }
        account._setState(.detailsEvicted(.libraryDeselected(uuid: uuid)))

        let viewModel = makeViewModel(libraryAccountID: uuid, appContainer: appContainer)
        await drainMainActor()

        let offersAChoice = cells(viewModel).contains { cell in
            if case .authMethod = cell { return true }
            return false
        }
        XCTAssertTrue(offersAChoice,
                      "A deselected multi-auth library's page must list its authentication methods so the patron can pick one.")
    }

    /// A signed-in page shows the account it is signed in with, not a method
    /// chooser: the credential-entry branch belongs to the signed-out case
    /// only, on a deselected library as much as on the selected one.
    func testAccountPage_WhenSignedInOnADeselectedLibrary_ShowsTheAccountNotAChooser() async throws {
        let appContainer = makeTestAppContainer()
        let uuid = "urn:uuid:pp5390-signedin-\(UUID().uuidString)"
        let account = try accountWithParsedAuthDocument(uuid: uuid, fixture: "nypl_authentication_document")
        let restore = appContainer.accountsManager._seedAccountForTesting(account)
        defer { restore() }
        account._setState(.detailsEvicted(.libraryDeselected(uuid: uuid)))

        let viewModel = makeViewModel(libraryAccountID: uuid,
                                      appContainer: appContainer,
                                      snapshot: signedInSnapshot())
        await drainMainActor()

        let rendered = cells(viewModel)
        XCTAssertTrue(viewModel.isSignedIn, "Precondition: the page is signed in to this library")
        XCTAssertTrue(rendered.contains(.logInSignOut),
                      "A signed-in page must offer the sign-out control for the library it is bound to.")
        XCTAssertFalse(rendered.contains { cell in
            if case .authMethod = cell { return true }
            return false
        }, "A signed-in page must not offer the authentication-method chooser.")
    }

    /// Signed in on a library whose method the app cannot name: the page must
    /// still not offer credential entry. The signed-out gate is a conjunction,
    /// and this is the state where dropping either half shows a signed-in
    /// patron a sign-in form.
    func testAccountPage_WhenSignedInAndNoMethodIsNamed_OffersNoCredentialFields() async throws {
        let appContainer = makeTestAppContainer()
        let uuid = "urn:uuid:pp5390-unnamed-\(UUID().uuidString)"
        let account = try accountWithTwoBasicMethods(uuid: uuid)
        let restore = appContainer.accountsManager._seedAccountForTesting(account)
        defer { restore() }
        account._setState(.detailsEvicted(.libraryDeselected(uuid: uuid)))

        let viewModel = makeViewModel(libraryAccountID: uuid,
                                      appContainer: appContainer,
                                      snapshot: signedInSnapshot())
        await drainMainActor()

        XCTAssertTrue(viewModel.isSignedIn, "Precondition: the page is signed in to this library")
        XCTAssertNil(viewModel.businessLogic.selectedAuthentication,
                     "Precondition: two methods and no browser-based one, so none is named")
        let rendered = cells(viewModel)
        XCTAssertFalse(rendered.contains(.barcode),
                       "A signed-in page must not offer credential entry.")
        XCTAssertFalse(rendered.contains { cell in
            if case .authMethod = cell { return true }
            return false
        }, "A signed-in page must not offer the method chooser either — the signed-out arm renders that, and this is the state where the gate's two halves can be told apart.")
    }

    // MARK: - The selected library

    /// The page a patron reaches on their first sign-in — selected library,
    /// document loaded, nothing stored — keeps its credential fields.
    func testAccountPage_WhenTheSelectedLibraryIsLoadedAndSignedOut_OffersTheSignInForm() async throws {
        let appContainer = makeTestAppContainer()
        let uuid = "urn:uuid:pp5390-selected-\(UUID().uuidString)"
        let account = try accountWithParsedAuthDocument(uuid: uuid, fixture: "acl_authentication_document")
        let restore = appContainer.accountsManager._seedAccountForTesting(account)
        defer { restore() }
        let details = try XCTUnwrap(account.details)
        account._setState(.detailsLoaded(details))

        let viewModel = makeViewModel(libraryAccountID: uuid, appContainer: appContainer)
        await drainMainActor()

        let rendered = cells(viewModel)
        XCTAssertTrue(rendered.contains(.barcode), "The selected library's sign-in form must be unchanged.")
        XCTAssertTrue(rendered.contains(.logInSignOut), "The selected library's Sign in button must be unchanged.")
    }

    /// On a multi-method library the first sign-in now lists the methods, the
    /// way the page has always listed them for a patron who signed in before.
    func testAccountPage_WhenTheSelectedMultiAuthLibraryIsSignedOut_ListsItsMethods() async throws {
        let appContainer = makeTestAppContainer()
        let uuid = "urn:uuid:pp5390-selected-multi-\(UUID().uuidString)"
        let account = try accountWithParsedAuthDocument(uuid: uuid, fixture: "nypl_authentication_document")
        let restore = appContainer.accountsManager._seedAccountForTesting(account)
        defer { restore() }
        let details = try XCTUnwrap(account.details)
        account._setState(.detailsLoaded(details))

        let viewModel = makeViewModel(libraryAccountID: uuid, appContainer: appContainer)
        await drainMainActor()

        XCTAssertTrue(cells(viewModel).contains { cell in
            if case .authMethod = cell { return true }
            return false
        }, "A multi-method library must list its methods on the first sign-in, not only after one.")
    }

    /// A library whose document gates on age rather than a card collects no
    /// credentials, so the page offers no fields — the form follows the
    /// document rather than appearing everywhere. It offers no age check
    /// either: `TPPAgeCheck` cannot present the picker for a deselected
    /// library and answers the check `false`, which discards that library's
    /// downloads and registry.
    func testAccountPage_WhenADeselectedLibraryGatesOnAge_OffersNeitherFieldsNorTheAgeCheck() async throws {
        let appContainer = makeTestAppContainer()
        let uuid = "urn:uuid:pp5390-agegate-\(UUID().uuidString)"
        let account = try accountWithParsedAuthDocument(uuid: uuid, fixture: "simplye_authentication_document")
        let restore = appContainer.accountsManager._seedAccountForTesting(account)
        defer { restore() }
        account._setState(.detailsEvicted(.libraryDeselected(uuid: uuid)))

        let viewModel = makeViewModel(libraryAccountID: uuid, appContainer: appContainer)
        await drainMainActor()

        let rendered = cells(viewModel)
        XCTAssertFalse(rendered.contains(.ageCheck),
                       "A deselected library's page must not offer the age check: answering it there resets the library's content with no picker shown.")
        XCTAssertFalse(rendered.contains(.barcode),
                       "A library that collects no credentials must not render a library-card field.")
        XCTAssertFalse(rendered.contains(.logInSignOut),
                       "A library that collects no credentials must not render a Sign in button.")
    }
}
