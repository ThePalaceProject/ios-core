//
//  AudiobookSessionManagerTests.swift
//  PalaceTests
//
//  Tests for AudiobookSessionManager: state transitions, SAML re-auth logic,
//  playback rate cycling, and session state properties.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - AudiobookSessionState Tests

final class AudiobookSessionStateTests: XCTestCase {

    func testIdleState() {
        let state = AudiobookSessionState.idle
        XCTAssertNil(state.bookId)
        XCTAssertFalse(state.isActive)
    }

    func testLoadingState() {
        let state = AudiobookSessionState.loading(bookId: "book-1")
        XCTAssertEqual(state.bookId, "book-1")
        XCTAssertTrue(state.isActive)
    }

    func testPlayingState() {
        let state = AudiobookSessionState.playing(bookId: "book-2")
        XCTAssertEqual(state.bookId, "book-2")
        XCTAssertTrue(state.isActive)
    }

    func testPausedState() {
        let state = AudiobookSessionState.paused(bookId: "book-3")
        XCTAssertEqual(state.bookId, "book-3")
        XCTAssertTrue(state.isActive)
    }

    func testErrorState() {
        let state = AudiobookSessionState.error(bookId: "book-4", message: "Failed")
        XCTAssertEqual(state.bookId, "book-4")
        XCTAssertFalse(state.isActive, "Error state should not be active")
    }

    func testStateEquality() {
        XCTAssertEqual(AudiobookSessionState.idle, AudiobookSessionState.idle)
        XCTAssertEqual(
            AudiobookSessionState.playing(bookId: "x"),
            AudiobookSessionState.playing(bookId: "x")
        )
        XCTAssertNotEqual(
            AudiobookSessionState.playing(bookId: "x"),
            AudiobookSessionState.paused(bookId: "x")
        )
        XCTAssertNotEqual(
            AudiobookSessionState.playing(bookId: "x"),
            AudiobookSessionState.playing(bookId: "y")
        )
    }
}

// MARK: - AudiobookSessionError Tests

final class AudiobookSessionErrorExtTests: XCTestCase {

    func testErrorEquality() {
        XCTAssertEqual(AudiobookSessionError.notAuthenticated, AudiobookSessionError.notAuthenticated)
        XCTAssertEqual(AudiobookSessionError.notDownloaded, AudiobookSessionError.notDownloaded)
        XCTAssertEqual(AudiobookSessionError.networkUnavailable, AudiobookSessionError.networkUnavailable)
        XCTAssertEqual(AudiobookSessionError.manifestLoadFailed, AudiobookSessionError.manifestLoadFailed)
        XCTAssertEqual(AudiobookSessionError.playerCreationFailed, AudiobookSessionError.playerCreationFailed)
        XCTAssertEqual(AudiobookSessionError.alreadyLoading, AudiobookSessionError.alreadyLoading)
        XCTAssertNotEqual(AudiobookSessionError.notAuthenticated, AudiobookSessionError.notDownloaded)
    }

    func testErrorDescriptions() {
        XCTAssertFalse(AudiobookSessionError.notAuthenticated.localizedDescription.isEmpty)
        XCTAssertFalse(AudiobookSessionError.notDownloaded.localizedDescription.isEmpty)
        XCTAssertFalse(AudiobookSessionError.networkUnavailable.localizedDescription.isEmpty)
        XCTAssertFalse(AudiobookSessionError.manifestLoadFailed.localizedDescription.isEmpty)
        XCTAssertFalse(AudiobookSessionError.playerCreationFailed.localizedDescription.isEmpty)
        XCTAssertFalse(AudiobookSessionError.alreadyLoading.localizedDescription.isEmpty)
    }

    func testUnknownErrorDescription() {
        let error = AudiobookSessionError.unknown("Custom error message")
        XCTAssertEqual(error.localizedDescription, "Custom error message")
    }

    func testUnknownErrorEquality() {
        XCTAssertEqual(
            AudiobookSessionError.unknown("msg"),
            AudiobookSessionError.unknown("msg")
        )
        XCTAssertNotEqual(
            AudiobookSessionError.unknown("a"),
            AudiobookSessionError.unknown("b")
        )
    }
}

// MARK: - SAML Re-auth Logic Tests

@MainActor
final class AudiobookSAMLReauthTests: XCTestCase {

    /// Tests the static helper that determines if SAML re-auth should be triggered
    /// after a playback failure. This is the PP-3703 regression prevention test.

    func testShouldNotTriggerSAMLReauthForNilError() {
        let mock = TPPUserAccountMock()
        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: nil,
            userAccount: mock,
            currentBook: TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        )
        XCTAssertFalse(result, "Nil error should not trigger re-auth")
    }

    func testShouldNotTriggerSAMLReauthForWrongDomain() {
        let mock = makeSAMLMockAccount()

        let error = NSError(domain: "com.other.domain", code: 5)
        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: mock,
            currentBook: TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        )
        XCTAssertFalse(result, "Wrong error domain should not trigger re-auth")
    }

    func testShouldNotTriggerSAMLReauthForWrongCode() {
        let mock = makeSAMLMockAccount()

        let error = NSError(domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer", code: 99)
        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: mock,
            currentBook: TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        )
        XCTAssertFalse(result, "Wrong error code should not trigger re-auth")
    }

    func testShouldNotTriggerSAMLReauthWithoutCredentials() {
        // Mock without credentials
        let mock = TPPUserAccountMock()
        // No credentials set = hasCredentials() returns false

        let error = NSError(domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer", code: 5)
        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: mock,
            currentBook: TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        )
        XCTAssertFalse(result, "Should not trigger re-auth without credentials")
    }

    func testShouldNotTriggerSAMLReauthWithNilBook() {
        let mock = makeSAMLMockAccount()

        let error = NSError(domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer", code: 5)
        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: mock,
            currentBook: nil
        )
        XCTAssertFalse(result, "Should not trigger re-auth without a current book")
    }

    func testShouldNotTriggerSAMLReauthForNonSAMLAuth() {
        // Mock with credentials but no auth definition (non-SAML)
        let mock = TPPUserAccountMock()
        mock._credentials = .barcodeAndPin(barcode: "123", pin: "456")
        // authDefinition is nil -> isSaml is false

        let error = NSError(domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer", code: 5)
        let result = AudiobookSessionManager.shouldTriggerSAMLReauthForPlaybackFailure(
            error: error,
            userAccount: mock,
            currentBook: TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        )
        XCTAssertFalse(result, "Should not trigger re-auth for non-SAML authentication")
    }

    // MARK: - Helpers

    /// Creates a TPPUserAccountMock configured with SAML auth and credentials.
    /// Uses NSCoding to create Authentication since there's no memberwise init.
    private func makeSAMLMockAccount() -> TPPUserAccountMock {
        let mock = TPPUserAccountMock()
        mock._credentials = .barcodeAndPin(barcode: "testuser", pin: "testpin")

        // Create SAML Authentication via NSCoding
        // The Authentication class's isSaml property checks authType == .saml
        let authData = makeSAMLAuthData()
        if let authData = authData,
           let auth = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: AccountDetails.Authentication.self,
               from: authData
           ) {
            mock._authDefinition = auth
        }

        return mock
    }

    /// Encodes a minimal SAML Authentication object via NSCoding.
    private func makeSAMLAuthData() -> Data? {
        // Build a minimal OPDS2 auth document JSON that results in SAML type
        let samlAuthJSON = """
        {
            "type": "http://librarysimplified.org/authtype/SAML-2.0",
            "description": "SAML Login"
        }
        """.data(using: .utf8)!

        // Try decoding the auth document
        if let authDoc = try? JSONDecoder().decode(OPDS2AuthenticationDocument.Authentication.self, from: samlAuthJSON) {
            let auth = AccountDetails.Authentication(auth: authDoc)
            return try? NSKeyedArchiver.archivedData(withRootObject: auth, requiringSecureCoding: false)
        }

        return nil
    }
}
