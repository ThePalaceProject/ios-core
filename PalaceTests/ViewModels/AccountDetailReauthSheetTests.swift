//
//  AccountDetailReauthSheetTests.swift
//  PalaceTests
//
//  The sign-in sheet opened for re-authentication (`forceReauthMode`) must
//  offer a way to sign in again when the stored credentials were refused,
//  for every auth type it serves (PP-5449). The Settings account page keeps
//  showing stale credentials as signed in (PP-3784).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountDetailReauthSheetTests: PalaceTestCase {

    private enum Credentials {
        case none, fresh, stale
    }

    /// The credentials the view model reads; tests change them mid-test.
    private final class CredentialsBox: @unchecked Sendable {
        var value: Credentials = .none
    }
    private let credentialsBox = CredentialsBox()
    private var currentCredentials: Credentials {
        get { credentialsBox.value }
        set { credentialsBox.value = newValue }
    }
    private var notificationSinks = Set<AnyCancellable>()
    /// The library the presented view model shows, and the manager that owns its account.
    private var presentedLibraryUUID = ""
    private var presentedAccountsManager: AccountsManager?

    override func tearDown() {
        notificationSinks.removeAll()
        presentedAccountsManager = nil
        super.tearDown()
    }

    private func account(uuid: String, authenticationJSON: String) throws -> Account {
        let json = """
        {
          "id": "\(uuid)",
          "title": "Reauth Library",
          "links": [],
          "authentication": [\(authenticationJSON)]
        }
        """
        let metadata = OPDS2Publication.Metadata(id: uuid, title: "Reauth Library")
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        let account = Account(publication: publication, imageCache: MockImageCache())
        account.authenticationDocument = try OPDS2AuthenticationDocument
            .fromData(try XCTUnwrap(json.data(using: .utf8)))
        account._setState(.detailsLoaded(try XCTUnwrap(account.details)))
        return account
    }

    private let basicAuthJSON = """
    {"type": "http://opds-spec.org/auth/basic", "description": "Library Barcode",
     "labels": {"login": "Barcode", "password": "PIN"},
     "inputs": {"login": {"keyboard": "Number pad"}, "password": {"keyboard": "Number pad"}}}
    """

    private let oidcAuthJSON = """
    {"type": "http://palaceproject.io/authtype/OpenIDConnect", "description": "Library SSO",
     "links": [{"href": "https://example.com/oidc/authenticate", "rel": "authenticate"}]}
    """

    private let samlAuthJSON = """
    {"type": "http://librarysimplified.org/authtype/SAML-2.0", "description": "University SSO Login",
     "links": [{"href": "https://example.com/saml/authenticate", "rel": "authenticate", "type": "text/html"}]}
    """

    nonisolated private static func snapshot(_ credentials: Credentials) -> TPPUserAccount.CredentialSnapshot {
        switch credentials {
        case .none:
            return TPPUserAccount.CredentialSnapshot(
                hasCredentials: false, hasAuthToken: false, authState: .loggedOut,
                barcode: nil, pin: nil, authToken: nil, authDefinition: nil, cookies: nil)
        case .fresh:
            return TPPUserAccount.CredentialSnapshot(
                hasCredentials: true, hasAuthToken: false, authState: .loggedIn,
                barcode: "01230000000237", pin: "old-pin", authToken: nil,
                authDefinition: nil, cookies: nil)
        case .stale:
            return TPPUserAccount.CredentialSnapshot(
                hasCredentials: true, hasAuthToken: false, authState: .credentialsStale,
                barcode: "01230000000237", pin: "old-pin", authToken: nil,
                authDefinition: nil, cookies: nil)
        }
    }

    /// Builds the view model the way `AccountDetailView` drives it: init, the
    /// init Task, then `onAppear` setting the mode and refreshing.
    private func presentedViewModel(
        authenticationJSON: String,
        credentials: Credentials,
        forceReauthMode: Bool,
        anotherLibraryIsCurrent: Bool = false
    ) async throws -> (AccountDetailViewModel, () -> Void) {
        let appContainer = makeTestAppContainer()
        let uuid = "urn:uuid:pp5449-\(UUID().uuidString)"
        let account = try account(uuid: uuid, authenticationJSON: authenticationJSON)
        var restore = appContainer.accountsManager._seedAccountForTesting(account)
        if anotherLibraryIsCurrent {
            // Seeding makes a library current, so seed a second one after it.
            let current = try self.account(uuid: "urn:uuid:pp5473-current-\(UUID().uuidString)",
                                           authenticationJSON: authenticationJSON)
            let restoreCurrent = appContainer.accountsManager._seedAccountForTesting(current)
            let restorePresented = restore
            restore = { restoreCurrent(); restorePresented() }
        }
        presentedLibraryUUID = uuid
        presentedAccountsManager = appContainer.accountsManager
        currentCredentials = credentials
        let viewModel = AccountDetailViewModel(
            libraryAccountID: uuid,
            accountsManager: appContainer.accountsManager,
            bookRegistry: appContainer.bookRegistry,
            downloadCenter: appContainer.downloadCenter,
            settings: appContainer.settings,
            userAccountPublisher: appContainer.userAccountPublisher,
            drmAuthorizerProvider: { nil },
            credentialSnapshotProvider: { [credentialsBox] _ in Self.snapshot(credentialsBox.value) },
            appNetwork: SignInAppNetworkSpy()
        )
        for _ in 0..<20 { await Task.yield() }
        viewModel.forceReauthMode = forceReauthMode
        viewModel.refreshSignInState()
        return (viewModel, restore)
    }

    /// Publishes a change from a library's stored account (the presented
    /// library's by default) and returns once the view model's subscriber has
    /// run: both hop through `RunLoop.main`, which delivers in order, and the
    /// view model subscribed first.
    private func publishAccountChange(libraryUUID: String? = nil) async throws {
        let manager = try XCTUnwrap(presentedAccountsManager)
        let account = manager.userAccount(for: libraryUUID ?? presentedLibraryUUID)
        let delivered = expectation(description: "account change delivered")
        account.changes
            .receive(on: RunLoop.main)
            .first()
            .sink { _ in delivered.fulfill() }
            .store(in: &notificationSinks)
        account._publishChangeForTesting()
        await fulfillment(of: [delivered], timeout: 5) // STARVE-001-OK: waits on one RunLoop.main delivery, not on async work
    }

    private func cells(_ viewModel: AccountDetailViewModel) -> [CellType] {
        viewModel.tableData.flatMap { $0 }
    }

    // MARK: - Basic auth in the re-auth sheet

    /// The reported defect: refused barcode/PIN rendered as disabled fields and
    /// a Sign Out button, so the patron could not enter new credentials.
    func testReauthSheet_WhenBasicCredentialsAreStale_OffersEmptyEditableSignInForm() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: basicAuthJSON, credentials: .stale, forceReauthMode: true)
        defer { restore() }

        XCTAssertFalse(viewModel.isSignedIn, "Fields are disabled and the button reads Sign Out while isSignedIn is true")
        XCTAssertEqual(viewModel.usernameText, "", "The refused barcode must not be prefilled")
        XCTAssertEqual(viewModel.pinText, "", "The refused PIN must not be prefilled")
        let rendered = cells(viewModel)
        XCTAssertTrue(rendered.contains(.barcode))
        XCTAssertTrue(rendered.contains(.pin))
        XCTAssertTrue(rendered.contains(.logInSignOut))
        XCTAssertFalse(viewModel.shouldShowSignInPrompt, "Basic auth has no browser prompt; it needs the form")
    }

    /// A credential change while the sheet is open must not turn the form
    /// back into the signed-in view.
    func testReauthSheet_WhenAccountChangesWhileOpen_KeepsSignInForm() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: basicAuthJSON, credentials: .stale, forceReauthMode: true)
        defer { restore() }

        try await publishAccountChange()

        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertEqual(viewModel.usernameText, "")
    }

    /// A token refresh for this library or another must not erase the
    /// barcode and PIN the patron is typing.
    func testReauthSheet_WhenAccountChangeArrivesWhileTyping_KeepsTypedCredentials() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: basicAuthJSON, credentials: .stale, forceReauthMode: true)
        defer { restore() }
        viewModel.usernameText = "01230000000999"
        viewModel.pinText = "new-pin"

        try await publishAccountChange()
        try await publishAccountChange(libraryUUID: "urn:uuid:pp5449-other-library")
        viewModel.refreshSignInState()

        XCTAssertEqual(viewModel.usernameText, "01230000000999")
        XCTAssertEqual(viewModel.pinText, "new-pin")
        XCTAssertFalse(viewModel.isSignedIn)
    }

    /// Another library's credential change says nothing about this library.
    func testReauthSheet_WhenAnotherLibrarysAccountChanges_IgnoresIt() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: basicAuthJSON, credentials: .stale, forceReauthMode: true)
        defer { restore() }
        currentCredentials = .fresh

        try await publishAccountChange(libraryUUID: "urn:uuid:pp5449-other-library")

        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertEqual(viewModel.usernameText, "")
    }

    /// A library the patron switched away from still follows its own
    /// account: signing in on its page must show it signed in.
    func testSettingsPage_WhenAnotherLibraryIsCurrent_FollowsItsOwnLibrarysAccount() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: basicAuthJSON, credentials: .none, forceReauthMode: false,
            anotherLibraryIsCurrent: true)
        defer { restore() }
        XCTAssertFalse(viewModel.isSignedIn)
        currentCredentials = .fresh

        try await publishAccountChange()

        XCTAssertTrue(viewModel.isSignedIn)
    }

    /// When the state really changes, the fields follow it: a sign-in fills
    /// them with the stored barcode, a sign-out empties them.
    func testReauthSheet_WhenSignedInStateChanges_RefillsThenClearsFields() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: basicAuthJSON, credentials: .stale, forceReauthMode: true)
        defer { restore() }
        viewModel.usernameText = "01230000000999"

        currentCredentials = .fresh
        try await publishAccountChange()
        XCTAssertTrue(viewModel.isSignedIn)
        XCTAssertEqual(viewModel.usernameText, "01230000000237")
        XCTAssertEqual(viewModel.pinText, "old-pin")

        currentCredentials = .none
        try await publishAccountChange()
        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertEqual(viewModel.usernameText, "")
        XCTAssertEqual(viewModel.pinText, "")
    }

    /// Typing new credentials in that form must enable the Sign In button.
    func testReauthSheet_WhenBasicCredentialsAreStale_TypedCredentialsEnableSignIn() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: basicAuthJSON, credentials: .stale, forceReauthMode: true)
        defer { restore() }

        viewModel.usernameText = "01230000000999"
        viewModel.pinText = "new-pin"

        XCTAssertTrue(viewModel.canSignIn)
        XCTAssertFalse(viewModel.isSignedIn, "The button routes to signIn() only while isSignedIn is false")
    }

    func testReauthSheet_WhenBasicCredentialsAreFresh_ShowsSignedIn() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: basicAuthJSON, credentials: .fresh, forceReauthMode: true)
        defer { restore() }

        XCTAssertTrue(viewModel.isSignedIn)
        XCTAssertEqual(viewModel.usernameText, "01230000000237")
    }

    func testReauthSheet_WhenNoBasicCredentials_OffersSignInForm() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: basicAuthJSON, credentials: .none, forceReauthMode: true)
        defer { restore() }

        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertTrue(cells(viewModel).contains(.barcode))
    }

    /// PP-3784: outside the re-auth sheet, stale credentials still read as
    /// signed in so the Settings page keeps offering Sign Out.
    func testSettingsPage_WhenBasicCredentialsAreStale_StillShowsSignedIn() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: basicAuthJSON, credentials: .stale, forceReauthMode: false)
        defer { restore() }

        XCTAssertTrue(viewModel.isSignedIn)
        XCTAssertEqual(viewModel.usernameText, "01230000000237")
    }

    // MARK: - Browser-based auth in the re-auth sheet

    func testReauthSheet_WhenOIDCCredentialsAreStale_ShowsBrowserSignInPrompt() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: oidcAuthJSON, credentials: .stale, forceReauthMode: true)
        defer { restore() }

        XCTAssertTrue(viewModel.shouldShowSignInPrompt)
    }

    func testReauthSheet_WhenOIDCCredentialsAreFresh_ShowsAccountList() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: oidcAuthJSON, credentials: .fresh, forceReauthMode: true)
        defer { restore() }

        XCTAssertFalse(viewModel.shouldShowSignInPrompt)
        XCTAssertTrue(viewModel.isSignedIn)
    }

    func testReauthSheet_WhenNoOIDCCredentials_ShowsBrowserSignInPrompt() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: oidcAuthJSON, credentials: .none, forceReauthMode: true)
        defer { restore() }

        XCTAssertTrue(viewModel.shouldShowSignInPrompt)
    }

    func testReauthSheet_WhenSAMLCredentialsAreStale_ShowsBrowserSignInPrompt() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: samlAuthJSON, credentials: .stale, forceReauthMode: true)
        defer { restore() }

        XCTAssertTrue(viewModel.shouldShowSignInPrompt)
    }

    func testReauthSheet_WhenSAMLCredentialsAreFresh_ShowsAccountList() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: samlAuthJSON, credentials: .fresh, forceReauthMode: true)
        defer { restore() }

        XCTAssertFalse(viewModel.shouldShowSignInPrompt)
    }

    func testReauthSheet_WhenNoSAMLCredentials_ShowsBrowserSignInPrompt() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: samlAuthJSON, credentials: .none, forceReauthMode: true)
        defer { restore() }

        XCTAssertTrue(viewModel.shouldShowSignInPrompt)
    }

    func testSettingsPage_WhenSAMLCredentialsAreStale_ShowsAccountList() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: samlAuthJSON, credentials: .stale, forceReauthMode: false)
        defer { restore() }

        XCTAssertFalse(viewModel.shouldShowSignInPrompt)
        XCTAssertTrue(viewModel.isSignedIn)
    }

    func testSettingsPage_WhenSAMLCredentialsAreFresh_ShowsAccountList() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: samlAuthJSON, credentials: .fresh, forceReauthMode: false)
        defer { restore() }

        XCTAssertFalse(viewModel.shouldShowSignInPrompt)
    }

    func testSettingsPage_WhenNoSAMLCredentials_ShowsBrowserSignInPrompt() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: samlAuthJSON, credentials: .none, forceReauthMode: false)
        defer { restore() }

        XCTAssertTrue(viewModel.shouldShowSignInPrompt)
    }

    /// PP-3784 for browser auth: the Settings page lists the account with
    /// Sign Out rather than replacing it with the sign-in prompt.
    func testSettingsPage_WhenOIDCCredentialsAreStale_ShowsAccountList() async throws {
        let (viewModel, restore) = try await presentedViewModel(
            authenticationJSON: oidcAuthJSON, credentials: .stale, forceReauthMode: false)
        defer { restore() }

        XCTAssertFalse(viewModel.shouldShowSignInPrompt)
        XCTAssertTrue(viewModel.isSignedIn)
    }
}
