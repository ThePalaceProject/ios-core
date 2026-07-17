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
import PalaceCatalog
@testable import Palace

// MARK: - AudiobookSessionState Tests

@MainActor
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

@MainActor
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
@MainActor
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

    /// Fully-downloaded books bypass network rules entirely — they must
    /// play under every (connected × onWiFi × wifiOnly) combination,
    /// including offline-with-Wi-Fi-only-on. Pin every cell of the matrix
    /// across both downloaded states (.downloadSuccessful and .used) so a
    /// mutant that adds a network gate to the downloaded path fails on
    /// the offline-with-Wi-Fi-only row.
    func testFullyDownloaded_bypassesNetworkRulesAcrossAllConnectivityCombinations() {
        for state in [TPPBookState.downloadSuccessful, .used] {
            XCTAssertNil(validate(state, connected: false, onWiFi: false, wifiOnly: true),
                         "\(state): offline + Wi-Fi-only on must NOT block — bytes are local")
            XCTAssertNil(validate(state, connected: true,  onWiFi: false, wifiOnly: true),
                         "\(state): cellular + Wi-Fi-only on must NOT block — bytes are local")
            XCTAssertNil(validate(state, connected: true,  onWiFi: true,  wifiOnly: true),
                         "\(state): on Wi-Fi must obviously not block")
            XCTAssertNil(validate(state, connected: true,  onWiFi: false, wifiOnly: false),
                         "\(state): cellular + Wi-Fi-only off — no gate")
        }
    }

    // MARK: Streaming books — the bug this fix addresses

    /// Streaming-state full validation matrix. The bug PP-XXXX exposed was
    /// that the open path skipped the Wi-Fi-only gate; the fix restored it.
    /// Lock every cell in one body so a mutant that flips ANY cell fails.
    /// Additionally pins the offline-preempt-wifi rule (offline must report
    /// .networkUnavailable, not .wifiRequired — that wording would mislead
    /// users into thinking Wi-Fi could solve a no-network situation).
    func testStreaming_networkValidationCoversAllConnectivityCombinations() {
        // On-Wi-Fi → always allowed (regardless of wifiOnly setting)
        XCTAssertNil(validate(.downloading, connected: true, onWiFi: true, wifiOnly: true))
        XCTAssertNil(validate(.downloading, connected: true, onWiFi: true, wifiOnly: false))

        // Cellular + wifiOnly OFF → user's choice, no gate
        XCTAssertNil(validate(.downloading, connected: true, onWiFi: false, wifiOnly: false))

        // Cellular + wifiOnly ON → .wifiRequired (the primary bug fix).
        // Pin both .downloading and .downloadFailed states.
        XCTAssertEqual(validate(.downloading,    connected: true, onWiFi: false, wifiOnly: true),
                       .wifiRequired,
                       "Cellular streaming with Wi-Fi-only ON must surface .wifiRequired")
        XCTAssertEqual(validate(.downloadFailed, connected: true, onWiFi: false, wifiOnly: true),
                       .wifiRequired,
                       ".downloadFailed (no local bytes) is treated as streaming — same gate")

        // Offline → .networkUnavailable (preempts wifiRequired, both wifiOnly values).
        XCTAssertEqual(validate(.downloading, connected: false, onWiFi: false, wifiOnly: false),
                       .networkUnavailable)
        XCTAssertEqual(validate(.downloading, connected: false, onWiFi: false, wifiOnly: true),
                       .networkUnavailable,
                       "Offline must report .networkUnavailable even with Wi-Fi-only on — connect-to-Wi-Fi wording would be misleading")
    }
}

// MARK: - Phone-side Alert Content Tests

/// Covers which errors surface a user-facing alert on the phone when emitted
/// through `errorPublisher`, and which are intentionally suppressed because
/// they have another dedicated presentation path (BookService.
/// showAudiobookTryAgainError or the cold-load alert branch).
@MainActor
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

// MARK: - PlaybackFailure Crashlytics Record Tests

/// Covers `AudiobookSessionManager.buildPlaybackFailureRecord` — the pure
/// builder behind the Crashlytics non-fatal recorded on every playback
/// failure. Background: BiblioBoard 403 responses on A1QA Test Library's
/// "Animal Farm" surfaced as a generic "A Problem Has Occurred" toast and
/// produced **zero** Crashlytics records, so the issue was invisible to ops.
/// These tests pin the userInfo shape so future regressions don't drop the
/// HTTP status / track URL / book id keys.
@MainActor
final class PlaybackFailureRecordTests: XCTestCase {

    private let kPalaceAudiobookDomain = "org.thepalaceproject.palace.audiobookPlayback"
    private let kOpenAccessDomain = "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer"

    func testRecord_NilError_RecordsBookIdAndDefaultCode() {
        let record = AudiobookSessionManager.buildPlaybackFailureRecord(
            error: nil, position: nil, bookId: "book-42"
        )
        XCTAssertEqual(record.domain, kPalaceAudiobookDomain)
        XCTAssertEqual(record.code, -1, "nil underlying error → record.code = -1 sentinel")
        XCTAssertEqual(record.userInfo["bookId"] as? String, "book-42")
        XCTAssertEqual(record.userInfo["trackTitle"] as? String, "unknown")
        XCTAssertEqual(record.userInfo["trackPosition"] as? String, "unknown")
        XCTAssertNil(record.userInfo["underlyingDomain"], "no underlying error → no underlyingDomain key")
    }

    func testRecord_NilBookId_FallsBackToUnknown() {
        let record = AudiobookSessionManager.buildPlaybackFailureRecord(
            error: nil, position: nil, bookId: nil
        )
        XCTAssertEqual(record.userInfo["bookId"] as? String, "unknown",
                       "missing bookId must not fail the record — fall back to 'unknown'")
    }

    func testRecord_OpenAccess403_PreservesHttpStatusAndUrl() {
        // Mirrors what OpenAccessDownloadTask now publishes on 403.
        let underlying = NSError(
            domain: kOpenAccessDomain,
            code: 6, // OpenAccessPlayerError.contentForbidden.rawValue
            userInfo: [
                NSLocalizedDescriptionKey: "Title Unavailable",
                "httpStatusCode": 403,
                "trackKey": "https://library.biblioboard.com/ext/api/media/abc/assets/content/SID-1_0001_64k.mp3",
                "url": "https://library.biblioboard.com/ext/api/media/abc/assets/content/SID-1_0001_64k.mp3",
            ]
        )
        let record = AudiobookSessionManager.buildPlaybackFailureRecord(
            error: underlying, position: nil, bookId: "loan-book-7"
        )
        // Record propagates the underlying code so Crashlytics groups by
        // contentForbidden rather than collapsing every audiobook error.
        XCTAssertEqual(record.code, 6, "underlying error code surfaces on the non-fatal")
        XCTAssertEqual(record.userInfo["underlyingDomain"] as? String, kOpenAccessDomain)
        XCTAssertEqual(record.userInfo["underlyingCode"] as? Int, 6)
        XCTAssertEqual(record.userInfo["httpStatusCode"] as? Int, 403,
                       "status code must round-trip — that's the whole point of this fix")
        XCTAssertEqual(
            record.userInfo["trackKey"] as? String,
            "https://library.biblioboard.com/ext/api/media/abc/assets/content/SID-1_0001_64k.mp3"
        )
        XCTAssertEqual(record.userInfo["bookId"] as? String, "loan-book-7")
    }

    func testRecord_OnlyAllowedSubKeysPropagate_BlocksAccidentalLeakage() {
        // The userInfo whitelist is "httpStatusCode | trackKey | url" — anything
        // else from underlying.userInfo (e.g. an internal session token) must
        // NOT leak into the Crashlytics record. Verify by including a junk key.
        let underlying = NSError(
            domain: kOpenAccessDomain,
            code: 5,
            userInfo: [
                "httpStatusCode": 401,
                "sessionToken": "DO-NOT-LOG-THIS-SECRET",
                "url": "https://example.com/track.mp3",
            ]
        )
        let record = AudiobookSessionManager.buildPlaybackFailureRecord(
            error: underlying, position: nil, bookId: "b"
        )
        XCTAssertEqual(record.userInfo["httpStatusCode"] as? Int, 401)
        XCTAssertEqual(record.userInfo["url"] as? String, "https://example.com/track.mp3")
        XCTAssertNil(record.userInfo["sessionToken"],
                     "sessionToken must NOT propagate — only the allow-listed keys leak through")
    }

    func testRecord_LocalizedDescriptionPrefixed() {
        let underlying = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let record = AudiobookSessionManager.buildPlaybackFailureRecord(
            error: underlying, position: nil, bookId: nil
        )
        let desc = record.userInfo[NSLocalizedDescriptionKey] as? String ?? ""
        XCTAssertTrue(desc.hasPrefix("Audiobook playback failed: "),
                      "operator-readable summary prefix should be present")
        XCTAssertTrue(desc.hasSuffix("boom"),
                      "underlying message should appear at the end of the summary")
    }
}

// MARK: - Chapter TOC normalization

/// Covers `AudiobookSessionManager.normalizedChaptersCount` — the primitive-
/// typed mirror of the binding-time TOC normalization. Exercises the call-
/// through to `ChapterTOCNormalizer` plus the collapse behavior (when the
/// TOC is oversubdivided, output count == trackCount).
@MainActor
final class AudiobookChapterTOCNormalizationTests: XCTestCase {

    func testNormalizedChaptersCount_balancedTOC_returnsOriginalCount() {
        // 56 tracks, 56 TOC entries — keep as-is.
        XCTAssertEqual(
            AudiobookSessionManager.normalizedChaptersCount(tocCount: 56, trackCount: 56),
            56
        )
    }

    func testNormalizedChaptersCount_slightlyInflatedTOC_returnsOriginalCount() {
        // 100 chapters + 1 "Acknowledgments" — under threshold, keep.
        XCTAssertEqual(
            AudiobookSessionManager.normalizedChaptersCount(tocCount: 101, trackCount: 100),
            101
        )
    }

    func testNormalizedChaptersCount_oversubdividedTOC_collapsesToTrackCount() {
        // The motivating case: 182 TOC for 56 tracks.
        // After collapse the chapter UI shows one entry per track.
        XCTAssertEqual(
            AudiobookSessionManager.normalizedChaptersCount(tocCount: 182, trackCount: 56),
            56
        )
    }

    func testNormalizedChaptersCount_zeroTracks_returnsOriginal() {
        // Defensive: can't decide without a track count → don't normalize.
        XCTAssertEqual(
            AudiobookSessionManager.normalizedChaptersCount(tocCount: 50, trackCount: 0),
            50
        )
    }

    func testNormalizedChaptersCount_exactlyAtThreshold_returnsOriginal() {
        // 56 * 1.5 == 84. 84 is the *boundary*, not over.
        XCTAssertEqual(
            AudiobookSessionManager.normalizedChaptersCount(tocCount: 84, trackCount: 56),
            84
        )
    }

    func testNormalizedChaptersCount_oneOverThreshold_collapses() {
        // 56 * 1.5 == 84. 85 > 84 → collapse to trackCount.
        XCTAssertEqual(
            AudiobookSessionManager.normalizedChaptersCount(tocCount: 85, trackCount: 56),
            56
        )
    }
}
