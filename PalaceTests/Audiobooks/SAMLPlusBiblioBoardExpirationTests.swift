//
//  SAMLPlusBiblioBoardExpirationTests.swift
//  PalaceTests
//
//  Unit tests for PP-3703: SAML + BiblioBoard double-expiration edge case.
//  When a BiblioBoard bearer token refresh fails due to SAML session expiration
//  (401 on the CM fulfill link), the app should trigger SAML re-login and
//  re-fetch the fulfill link after re-auth. These tests protect the predicate
//  that decides when to trigger that flow.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - shouldTriggerSAMLReauthForPlaybackFailure Predicate Tests

@MainActor
final class SAMLPlusBiblioBoardExpirationTests: XCTestCase {

    private var userAccountMock: TPPUserAccountMock!
    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        userAccountMock = TPPUserAccountMock()
        libraryMock = TPPLibraryAccountMock()
    }

    override func tearDown() {
        userAccountMock?.removeAll()
        userAccountMock = nil
        libraryMock = nil
        super.tearDown()
    }

    // MARK: - Triggers re-auth (true)

    func testShouldTriggerSAMLReauth_AuthRequiredError_SAML_Credentials_Book_ReturnsTrue() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        userAccountMock.setAuthState(.loggedIn)

        let error = NSError(
            domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer",
            code: 5, // OpenAccessPlayerError.authenticationRequired
            userInfo: nil
        )
        let book = TPPBookMocker.mockBook(title: "Test Audiobook", authors: "Author")

        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: userAccountMock,
            currentBook: book
        )

        XCTAssertTrue(result, "Should trigger SAML re-auth when bearer token refresh fails (auth required) with SAML account and credentials")
    }

    // MARK: - Does not trigger re-auth (false)

    func testShouldTriggerSAMLReauth_NilError_ReturnsFalse() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: nil,
            userAccount: userAccountMock,
            currentBook: book
        )

        XCTAssertFalse(result)
    }

    func testShouldTriggerSAMLReauth_WrongErrorDomain_ReturnsFalse() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        let error = NSError(domain: "other.domain", code: 5, userInfo: nil)

        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: userAccountMock,
            currentBook: book
        )

        XCTAssertFalse(result)
    }

    func testShouldTriggerSAMLReauth_WrongErrorCode_ReturnsFalse() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        let error = NSError(
            domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer",
            code: 0, // e.g. unknown
            userInfo: nil
        )

        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: userAccountMock,
            currentBook: book
        )

        XCTAssertFalse(result)
    }

    func testShouldTriggerSAMLReauth_OAuthAccount_ReturnsFalse() {
        userAccountMock._authDefinition = libraryMock.oauthAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        let error = NSError(
            domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer",
            code: 5,
            userInfo: nil
        )

        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: userAccountMock,
            currentBook: book
        )

        XCTAssertFalse(result, "OAuth accounts use token refresh, not SAML re-auth flow")
    }

    func testShouldTriggerSAMLReauth_NoCredentials_ReturnsFalse() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = nil
        userAccountMock.setAuthState(.loggedOut)
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        let error = NSError(
            domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer",
            code: 5,
            userInfo: nil
        )

        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: userAccountMock,
            currentBook: book
        )

        XCTAssertFalse(result, "No credentials means no SAML session to refresh")
    }

    func testShouldTriggerSAMLReauth_NilCurrentBook_ReturnsFalse() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")

        let error = NSError(
            domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer",
            code: 5,
            userInfo: nil
        )

        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: userAccountMock,
            currentBook: nil
        )

        XCTAssertFalse(result, "Need a current book to re-open after re-auth")
    }

    func testShouldTriggerSAMLReauth_BasicAuth_ReturnsFalse() {
        userAccountMock._authDefinition = libraryMock.barcodeAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        let error = NSError(
            domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer",
            code: 5,
            userInfo: nil
        )

        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: userAccountMock,
            currentBook: book
        )

        XCTAssertFalse(result, "Basic auth does not use SAML re-auth flow")
    }
}
