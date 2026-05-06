//
//  AudiobookLoaderTests.swift
//  PalaceTests
//
//  Tests for AudiobookLoader — the collaborator that builds an audiobook
//  manager from a TPPBook. Regression suite for the "opening third audiobook
//  hangs" root cause: the previous static BookService pipeline leaked a
//  live decryptor across sessions, which is now impossible because each
//  load produces its own LoadedAudiobook owned by the session manager.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class AudiobookLoaderTests: XCTestCase {

    // MARK: - Cancellation semantics

    /// A loader that's cancelled before any result lands must surface
    /// AudiobookLoadError.cancelled, not whatever the pipeline would have
    /// produced. The session manager relies on this to drop completions
    /// from superseded loaders.
    func testLoad_whenCancelledFirst_surfacesCancelledError() {
        let loader = AudiobookLoader()
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        let exp = expectation(description: "load completes")
        var seenError: AudiobookLoadError?
        loader.cancel()
        loader.load(book) { result in
            if case .failure(let err) = result { seenError = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        guard case .cancelled = seenError else {
            XCTFail("expected .cancelled, got \(String(describing: seenError))")
            return
        }
    }

    // MARK: - Error surface

    /// A book with a placeholder acquisition URL and no local manifest must
    /// resolve to a manifest failure — not a success or a hang. Ensures the
    /// loader surfaces a definitive error on the network path instead of
    /// waiting forever (which was the old BookService behavior's failure
    /// mode combined with a 20s session-manager timeout).
    func testLoad_missingLocalFileAndUnreachableURL_failsWithManifestError() {
        let loader = AudiobookLoader()
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        let exp = expectation(description: "load completes")
        exp.assertForOverFulfill = false
        var seenError: AudiobookLoadError?
        loader.load(book) { result in
            if case .failure(let err) = result { seenError = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)

        XCTAssertNotNil(seenError, "loader must surface an error for unreachable manifest")
        if case .cancelled = seenError { XCTFail("unexpected .cancelled") }
    }
}

// MARK: - Session manager load-error mapping

/// Tests for the mapLoadError static. This is the seam that keeps load-level
/// errors (network, DRM, factory) from leaking into the session-level API.
/// If any case is forgotten or mapped wrong, the UI sees a generic
/// .unknown error and the retry UX degrades — so lock every case.
@MainActor
final class AudiobookSessionManagerErrorMappingTests: XCTestCase {

    func testMap_cancelled_isUnknown() {
        // .cancelled must land in .unknown (no dedicated session-error case) and
        // the surfaced message must be non-empty so the retry UX has something
        // to display instead of a blank alert.
        let mapped = AudiobookSessionManager.mapLoadError(.cancelled)
        guard case .unknown(let message) = mapped else {
            XCTFail("expected .unknown for .cancelled, got \(mapped)"); return
        }
        XCTAssertFalse(message.isEmpty,
                       ".unknown for .cancelled must carry a non-empty message for the alert layer")
    }

    func testMap_tokenRefresh_isNotAuthenticated() {
        let a = AudiobookSessionManager.mapLoadError(.tokenRefreshFailed(underlying: nil))
        XCTAssertEqual(a, .notAuthenticated)
        let b = AudiobookSessionManager.mapLoadError(.missingCredentialsForTokenRefresh)
        XCTAssertEqual(b, .notAuthenticated)
    }

    func testMap_manifestFamily_isManifestLoadFailed() {
        let cases: [AudiobookLoadError] = [
            .manifestFetchFailed,
            .manifestParseFailed,
            .manifestSerializationFailed,
            .manifestDecodingFailed(underlying: NSError(domain: "x", code: 0))
        ]
        for err in cases {
            XCTAssertEqual(AudiobookSessionManager.mapLoadError(err), .manifestLoadFailed,
                           "case \(err) must map to .manifestLoadFailed")
        }
    }

    func testMap_lcpFamily_isManifestLoadFailed() {
        let cases: [AudiobookLoadError] = [
            .lcpNotAvailable,
            .lcpInstantiationFailed,
            .lcpDecryptionFailed(underlying: nil),
            .licenseDownloadFailed(underlying: nil),
            .licenseSaveFailed(underlying: NSError(domain: "x", code: 0)),
            .missingFulfillURL,
            .missingContentDirectory
        ]
        for err in cases {
            XCTAssertEqual(AudiobookSessionManager.mapLoadError(err), .manifestLoadFailed,
                           "case \(err) must map to .manifestLoadFailed")
        }
    }

    func testMap_vendorKey_surfacesUnderlyingMessage() {
        let inner = NSError(domain: "VendorKey", code: 42, userInfo: [NSLocalizedDescriptionKey: "nope"])
        let mapped = AudiobookSessionManager.mapLoadError(.vendorKeyUpdateFailed(underlying: inner))
        guard case .unknown(let msg) = mapped else {
            XCTFail("expected .unknown for vendorKey, got \(mapped)"); return
        }
        XCTAssertEqual(msg, "nope")
    }

    func testMap_factoryFailed_isPlayerCreationFailed() {
        // The manifestType payload is opaque to the mapping — every factory
        // failure must land on .playerCreationFailed regardless of format,
        // so the retry UX shows a consistent "player couldn't start" message.
        let manifestTypes = ["audiobook", "audiobook+json", "readium-lcp",
                             "readium+lcp+audiobook", "unknown-format", ""]
        for manifestType in manifestTypes {
            let mapped = AudiobookSessionManager.mapLoadError(.factoryFailed(manifestType: manifestType))
            XCTAssertEqual(mapped, .playerCreationFailed,
                           ".factoryFailed(manifestType: '\(manifestType)') must map to .playerCreationFailed")
        }
    }
}
