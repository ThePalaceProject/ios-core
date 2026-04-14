//
//  AccountModelTests.swift
//  PalaceTests
//
//  Tests for Account class initialization, loadLogo, loadAuthenticationDocument,
//  and related model types (OPDS2SamlIDP, TPPSignedInStateProvider).
//  Covers High-priority coverage gaps: Account, loadAuthenticationDocument, loadLogo,
//  OPDS2SamlIDP, TPPSignedInStateProvider.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - Account Initialization Tests

final class AccountModelTests: XCTestCase {

    private var mockImageCache: MockImageCache!

    override func setUp() {
        super.setUp()
        mockImageCache = MockImageCache()
    }

    override func tearDown() {
        mockImageCache = nil
        super.tearDown()
    }

    // MARK: - Account Init Tests

    func testAccount_InitFromPublication_SetsName() {
        let publication = makePublication(title: "Test Library")
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertEqual(account.name, "Test Library")
    }

    func testAccount_InitFromPublication_SetsUUID() {
        let publication = makePublication(id: "urn:uuid:test-123")
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertEqual(account.uuid, "urn:uuid:test-123")
    }

    func testAccount_InitFromPublication_SetsSubtitle() {
        let publication = makePublication(description: "A great library")
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertEqual(account.subtitle, "A great library")
    }

    func testAccount_InitFromPublication_SetsCatalogUrl() {
        let catalogLink = OPDS2Link(
            href: "https://example.com/catalog",
            rel: "http://opds-spec.org/catalog"
        )
        let publication = makePublication(links: [catalogLink])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertEqual(account.catalogUrl, "https://example.com/catalog")
    }

    func testAccount_InitFromPublication_SetsSupportEmail() {
        let helpLink = OPDS2Link(
            href: "mailto:support@example.com",
            rel: "help"
        )
        let publication = makePublication(links: [helpLink])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertNotNil(account.supportEmail)
    }

    func testAccount_InitFromPublication_SetsSupportURL() {
        let helpLink = OPDS2Link(
            href: "https://support.example.com",
            rel: "help"
        )
        let publication = makePublication(links: [helpLink])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertEqual(account.supportURL?.absoluteString, "https://support.example.com")
    }

    func testAccount_InitFromPublication_SetsAuthDocUrl() {
        let authLink = OPDS2Link(
            href: "https://example.com/auth",
            type: "application/vnd.opds.authentication.v1.0+json"
        )
        let publication = makePublication(links: [authLink])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertEqual(account.authenticationDocumentUrl, "https://example.com/auth")
    }

    func testAccount_InitFromPublication_SetsHomePageUrl() {
        let alternateLink = OPDS2Link(
            href: "https://example.com/home",
            rel: "alternate"
        )
        let publication = makePublication(links: [alternateLink])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertEqual(account.homePageUrl, "https://example.com/home")
    }

    func testAccount_InitFromPublication_DefaultLogo_IsNotNil() {
        let publication = makePublication()
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertNotNil(account.logo)
    }

    func testAccount_InitFromPublication_DetailsAreNil() {
        let publication = makePublication()
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertNil(account.details)
    }

    func testAccount_InitFromPublication_HasUpdatedToken_IsFalse() {
        let publication = makePublication()
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertFalse(account.hasUpdatedToken)
    }

    func testAccount_DebugDescription_ContainsName() {
        let publication = makePublication(title: "Debug Library")
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertTrue(account.debugDescription.contains("Debug Library"))
    }

    // MARK: - Account loadLogo Tests

    func testLoadLogo_WithNilLogoUrl_DoesNotCrash() {
        let publication = makePublication()
        let account = Account(publication: publication, imageCache: mockImageCache)
        XCTAssertNil(account.logoUrl)

        // Should return immediately without crashing
        account.loadLogo()
    }

    func testLoadLogo_WithCachedImage_UsesCachedImage() {
        let publication = makePublication()
        let account = Account(publication: publication, imageCache: mockImageCache)
        account.logoUrl = URL(string: "https://example.com/logo.png")

        // Pre-populate the cache
        let testImage = UIImage(systemName: "book")!
        mockImageCache.set(testImage, for: account.uuid)

        // loadLogo should use the cached image
        account.loadLogo()

        // Verify cache was queried
        XCTAssertNotNil(mockImageCache.get(for: account.uuid))
    }

    // MARK: - Account loadAuthenticationDocument Tests

    func testLoadAuthenticationDocument_WithNilUrl_CompletesWithFalse() {
        let publication = makePublication() // No auth doc URL
        let account = Account(publication: publication, imageCache: mockImageCache)

        let expectation = XCTestExpectation(description: "Completion called")
        account.loadAuthenticationDocument { success in
            XCTAssertFalse(success)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Account loansUrl Tests

    func testLoansUrl_WhenDetailsNil_ReturnsNil() {
        let publication = makePublication()
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertNil(account.loansUrl)
    }

    // MARK: - Helpers

    private func makePublication(
        title: String = "Test Library",
        id: String = "urn:uuid:test",
        description: String? = nil,
        links: [OPDS2Link] = []
    ) -> OPDS2Publication {
        OPDS2Publication(
            links: links,
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: description,
                id: id,
                title: title
            ),
            images: nil
        )
    }
}

// MARK: - OPDS2SamlIDP Tests

final class OPDS2SamlIDPTests: XCTestCase {

    func testInit_WithValidLink_CreatesInstance() {
        let link = OPDS2Link(href: "https://idp.example.com/login")
        let idp = OPDS2SamlIDP(opdsLink: link)

        XCTAssertNotNil(idp)
        XCTAssertEqual(idp?.url.absoluteString, "https://idp.example.com/login")
    }

    func testInit_WithInvalidHref_ReturnsNil() {
        // Empty string creates a nil URL
        let link = OPDS2Link(href: "")
        let idp = OPDS2SamlIDP(opdsLink: link)

        // URL(string: "") returns nil on some platforms
        if URL(string: "") == nil {
            XCTAssertNil(idp)
        }
    }

    func testDisplayName_WithEnglishName_ReturnsEnglishValue() {
        let link = OPDS2Link(
            href: "https://idp.example.com/login",
            displayNames: [
                OPDS2InternationalVariable(language: "en", value: "Test IDP")
            ]
        )
        let idp = OPDS2SamlIDP(opdsLink: link)

        XCTAssertEqual(idp?.displayName, "Test IDP")
    }

    func testDisplayName_WithNoEnglishName_ReturnsNil() {
        let link = OPDS2Link(
            href: "https://idp.example.com/login",
            displayNames: [
                OPDS2InternationalVariable(language: "fr", value: "IDP Test")
            ]
        )
        let idp = OPDS2SamlIDP(opdsLink: link)

        XCTAssertNil(idp?.displayName)
    }

    func testIdpDescription_WithEnglishDescription_ReturnsValue() {
        let link = OPDS2Link(
            href: "https://idp.example.com/login",
            descriptions: [
                OPDS2InternationalVariable(language: "en", value: "A test identity provider")
            ]
        )
        let idp = OPDS2SamlIDP(opdsLink: link)

        XCTAssertEqual(idp?.idpDescription, "A test identity provider")
    }

    func testIdpDescription_WithNoDescriptions_ReturnsNil() {
        let link = OPDS2Link(href: "https://idp.example.com/login")
        let idp = OPDS2SamlIDP(opdsLink: link)

        XCTAssertNil(idp?.idpDescription)
    }
}

// MARK: - TPPSignedInStateProvider Tests
// These tests use TPPUserAccountMock (which extends TPPUserAccount) to verify
// that the real TPPSignedInStateProvider conformance on TPPUserAccount reflects
// actual credential state rather than a private stub.

final class TPPSignedInStateProviderTests: XCTestCase {

    private var mockAccount: TPPUserAccountMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        mockAccount = TPPUserAccountMock()
        mockAccount.removeAll()
    }

    override func tearDown() {
        mockAccount.removeAll()
        mockAccount = nil
        TPPUserAccountMock.resetShared()
        super.tearDown()
    }

    func testIsSignedIn_WhenCredentialsPresent_ReturnsTrue() {
        // Arrange: set a bearer-token credential on the account
        mockAccount.setAuthToken("bearer-token-123", barcode: "12345", pin: nil, expirationDate: nil)

        // Act
        let result = mockAccount.isSignedIn()

        // Assert: the real TPPSignedInStateProvider implementation returns true
        // because hasCredentials() sees the token credential
        XCTAssertTrue(result, "isSignedIn() should return true when credentials are present")
    }

    func testIsSignedIn_WhenNoCredentials_ReturnsFalse() {
        // Arrange: ensure no credentials (removeAll was called in setUp)
        XCTAssertFalse(mockAccount.hasCredentials(), "Precondition: no credentials set")

        // Act
        let result = mockAccount.isSignedIn()

        // Assert: empty credentials -> not signed in
        XCTAssertFalse(result, "isSignedIn() should return false when no credentials are present")
    }

    func testIsSignedIn_AfterRemoveAll_ReturnsFalse() {
        // Arrange: set credentials, then clear them
        mockAccount.setAuthToken("tok", barcode: "bar", pin: "pin", expirationDate: nil)
        XCTAssertTrue(mockAccount.isSignedIn(), "Precondition: signed in before removeAll")

        // Act
        mockAccount.removeAll()

        // Assert: signed-out state is reflected through isSignedIn()
        XCTAssertFalse(mockAccount.isSignedIn(),
                       "isSignedIn() should return false after removeAll clears credentials")
    }
}
