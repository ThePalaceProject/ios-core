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
        XCTAssertEqual(AudiobookSessionError.wifiRequired, AudiobookSessionError.wifiRequired)
        XCTAssertEqual(AudiobookSessionError.manifestLoadFailed, AudiobookSessionError.manifestLoadFailed)
        XCTAssertEqual(AudiobookSessionError.playerCreationFailed, AudiobookSessionError.playerCreationFailed)
        XCTAssertEqual(AudiobookSessionError.alreadyLoading, AudiobookSessionError.alreadyLoading)
        XCTAssertNotEqual(AudiobookSessionError.notAuthenticated, AudiobookSessionError.notDownloaded)
        XCTAssertNotEqual(AudiobookSessionError.networkUnavailable, AudiobookSessionError.wifiRequired,
                          "wifiRequired must be distinguishable from networkUnavailable — they map to different alert titles")
    }

    func testErrorDescriptions() {
        XCTAssertFalse(AudiobookSessionError.notAuthenticated.localizedDescription.isEmpty)
        XCTAssertFalse(AudiobookSessionError.notDownloaded.localizedDescription.isEmpty)
        XCTAssertFalse(AudiobookSessionError.networkUnavailable.localizedDescription.isEmpty)
        XCTAssertFalse(AudiobookSessionError.wifiRequired.localizedDescription.isEmpty,
                       "wifiRequired must carry a non-empty message so the alert layer has something to display")
        XCTAssertFalse(AudiobookSessionError.manifestLoadFailed.localizedDescription.isEmpty)
        XCTAssertFalse(AudiobookSessionError.playerCreationFailed.localizedDescription.isEmpty)
        XCTAssertFalse(AudiobookSessionError.alreadyLoading.localizedDescription.isEmpty)
    }

    func testUnknownErrorDescription_preservesCallerMessageVerbatim() {
        // .unknown forwards the caller's message to the UI unchanged. Covers
        // simple strings, empty strings (still a valid payload, not nil), and
        // multi-line content that shows up in Crashlytics breadcrumbs.
        let cases = [
            "Custom error message",
            "",
            "line one\nline two\t\"quoted\"",
            "emoji 📚 and unicode é"
        ]
        for message in cases {
            XCTAssertEqual(AudiobookSessionError.unknown(message).localizedDescription,
                           message,
                           ".unknown must return the input message verbatim for '\(message)'")
        }
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

// MARK: - Network Validation Tests

/// Covers every combination of (bookState, connected, onWiFi, downloadOnlyOnWiFi).
/// These rules decide whether a user's attempt to open an audiobook is refused
/// before the loader runs — the surface that fires the WiFi-required alert on
/// open (parallel to MyBooksDownloadCenter's download-site gate added in PR #851).
final class AudiobookNetworkValidationTests: XCTestCase {

    private func validate(
        _ state: TPPBookState,
        connected: Bool,
        onWiFi: Bool,
        wifiOnly: Bool
    ) -> AudiobookSessionError? {
        AudiobookSessionManager.networkValidationError(
            bookState: state,
            isConnectedToNetwork: connected,
            isOnWiFi: onWiFi,
            downloadOnlyOnWiFi: wifiOnly
        )
    }

    // MARK: Fully-downloaded books — network rules must not apply

    func testFullyDownloaded_neverNeedsNetwork_offline() {
        XCTAssertNil(validate(.downloadSuccessful, connected: false, onWiFi: false, wifiOnly: true),
                     "Downloaded audiobook must play offline regardless of Wi-Fi-only preference")
        XCTAssertNil(validate(.used, connected: false, onWiFi: false, wifiOnly: true),
                     ".used state (already-opened downloaded book) must also play offline")
    }

    func testFullyDownloaded_onCellularWithWifiOnly_isAllowed() {
        XCTAssertNil(validate(.downloadSuccessful, connected: true, onWiFi: false, wifiOnly: true),
                     "Downloaded audiobook must play on cellular even with Wi-Fi-only on — no bytes going over the wire")
    }

    // MARK: Streaming books — the bug this fix addresses

    func testStreaming_onCellularWithWifiOnly_returnsWifiRequired() {
        XCTAssertEqual(validate(.downloading, connected: true, onWiFi: false, wifiOnly: true),
                       .wifiRequired,
                       "Streaming on cellular with Wi-Fi-only ON must surface .wifiRequired — the exact alert the open path was silently skipping before this fix")
        XCTAssertEqual(validate(.downloadFailed, connected: true, onWiFi: false, wifiOnly: true),
                       .wifiRequired,
                       ".downloadFailed is also a non-downloaded state — Wi-Fi-only gate must still fire")
    }

    func testStreaming_onWifi_isAllowed() {
        XCTAssertNil(validate(.downloading, connected: true, onWiFi: true, wifiOnly: true),
                     "Streaming on Wi-Fi must be allowed — the setting name is 'download only on Wi-Fi', not 'block streaming'")
    }

    func testStreaming_onCellularWithoutWifiOnly_isAllowed() {
        XCTAssertNil(validate(.downloading, connected: true, onWiFi: false, wifiOnly: false),
                     "Without the Wi-Fi-only preference, cellular streaming is the user's choice — no gate")
    }

    func testStreaming_offline_returnsNetworkUnavailable() {
        XCTAssertEqual(validate(.downloading, connected: false, onWiFi: false, wifiOnly: false),
                       .networkUnavailable,
                       "No network + streaming content must return the generic offline error, not the Wi-Fi-specific one")
    }

    func testStreaming_offline_preemptsWifiOnlyCheck() {
        // If the device is fully offline, .networkUnavailable is more accurate
        // than .wifiRequired — the user can't solve it by toggling a setting.
        XCTAssertEqual(validate(.downloading, connected: false, onWiFi: false, wifiOnly: true),
                       .networkUnavailable,
                       "Offline must report .networkUnavailable even with Wi-Fi-only on — connect-to-Wi-Fi wording would be misleading")
    }

    // MARK: Boundary / sanity

    func testRulesAreIndependentOfAuthAndRegistration() {
        // networkValidationError is a pure function — it doesn't touch auth or
        // registration state, because validateRequirements already gated those
        // separately. A mutation that added an auth check here would silently
        // break the downloaded-offline path (fully-downloaded books must play
        // without reaching out to the auth stack).
        for state in [TPPBookState.downloadSuccessful, .used] {
            XCTAssertNil(validate(state, connected: false, onWiFi: false, wifiOnly: true),
                         "Downloaded state \(state) must return nil regardless of network/wifi state")
        }
    }
}

// MARK: - Phone-side Alert Content Tests

/// Covers which errors surface a user-facing alert on the phone when emitted
/// through `errorPublisher`, and which are intentionally suppressed because
/// they have another dedicated presentation path (BookService.
/// showAudiobookTryAgainError or the cold-load alert branch).
final class AudiobookPhoneAlertContentTests: XCTestCase {

    func testWifiRequired_producesAlertContent() {
        guard let content = AudiobookSessionManager.phoneAlertContent(for: .wifiRequired) else {
            XCTFail(".wifiRequired must produce phone alert content — it's the primary bug this fix addresses")
            return
        }
        XCTAssertFalse(content.title.isEmpty, "title cannot be empty")
        XCTAssertFalse(content.message.isEmpty, "message cannot be empty")
        XCTAssertTrue(content.title.localizedCaseInsensitiveContains("Wi-Fi") ||
                      content.title.localizedCaseInsensitiveContains("wifi"),
                      ".wifiRequired title must mention Wi-Fi so users understand the gate")
    }

    func testValidationErrors_allProduceAlertContent() {
        // Every validation-failure error must have phone alert content — if any
        // returned nil, the user would get no feedback after tapping Listen and
        // that's the original "no alert" bug.
        let validationErrors: [AudiobookSessionError] = [
            .wifiRequired,
            .notAuthenticated,
            .notDownloaded,
            .networkUnavailable,
        ]
        for error in validationErrors {
            XCTAssertNotNil(AudiobookSessionManager.phoneAlertContent(for: error),
                            "\(error) is a validation-failure error and MUST produce phone alert content")
        }
    }

    func testLoaderAndUnknownErrors_returnNil_toAvoidDoubleAlerts() {
        // These errors are already alerted through other paths:
        //   - .manifestLoadFailed / .playerCreationFailed → loader path calls
        //     BookService.showAudiobookTryAgainError
        //   - .unknown("Playback failed") → cold-load branch in
        //     handleManagerState(.playbackFailed)
        //   - .alreadyLoading → programmer-facing signal, not user-facing
        let suppressed: [AudiobookSessionError] = [
            .manifestLoadFailed,
            .playerCreationFailed,
            .alreadyLoading,
            .unknown("anything"),
            .unknown(""),
        ]
        for error in suppressed {
            XCTAssertNil(AudiobookSessionManager.phoneAlertContent(for: error),
                         "\(error) must return nil so the subscriber does not double-alert with existing paths")
        }
    }
}
