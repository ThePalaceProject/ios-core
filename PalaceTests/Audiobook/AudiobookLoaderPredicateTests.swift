//
//  AudiobookLoaderPredicateTests.swift
//  PalaceTests
//
//  Mutation-killing tests for the two deterministic predicates extracted
//  from AudiobookLoader.swift:
//
//    1. `hasRefreshableCredentials(username:pin:tokenURL:)` — gates the
//       token refresh path on line 109's `tokenURL != nil` clause. Without
//       a focused test, that mutation point survives every behavioural
//       test in the loader bundle (the surrounding code path needs
//       AppContainer.production() + the network, which isolated unit tests
//       refuse to touch).
//    2. `looksLikeHTMLResponse(_:)` — gates the diagnostic-logging branch
//       on line 372's `Content-Type contains "html"` check. Same kill-rate
//       problem: nothing else in the suite drives this with a real
//       HTTPURLResponse.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AudiobookLoaderPredicateTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - hasRefreshableCredentials

    private let validTokenURL = URL(string: "https://library.test/token")!

    /// All three components present — the loader's happy path. This is the
    /// case the mutation on line 109 (`tokenURL != nil` → `== nil`) flips:
    /// original returns `true`, mutant returns `false`. The assertion
    /// `XCTAssertTrue` fails the mutant.
    func testHasRefreshableCredentials_allPresent_returnsTrue() {
        XCTAssertTrue(
            AudiobookLoader.hasRefreshableCredentials(
                username: "alice",
                pin: "1234",
                tokenURL: validTokenURL
            ),
            "Username + PIN + tokenURL all present must permit refresh — kill point for the line 109 mutation"
        )
    }

    /// tokenURL nil — the path the refreshTokenIfNeeded guard bails on.
    /// Even with username and PIN present, missing tokenURL must drop to
    /// `.missingCredentialsForTokenRefresh`. Companion to the positive
    /// case above so the predicate's TRUE/FALSE bifurcation around the
    /// `tokenURL != nil` branch is fully pinned.
    func testHasRefreshableCredentials_nilTokenURL_returnsFalse() {
        XCTAssertFalse(
            AudiobookLoader.hasRefreshableCredentials(
                username: "alice",
                pin: "1234",
                tokenURL: nil
            ),
            "nil tokenURL must disqualify refresh even with valid username + PIN"
        )
    }

    /// Username missing — the guard's first short-circuit. The branch
    /// order matters: tokenURL never gets evaluated if username is bad,
    /// so a regression that re-orders the guards (e.g. checks tokenURL
    /// first and crashes on a nil username) would not be caught by the
    /// other tests in this class.
    func testHasRefreshableCredentials_nilUsername_returnsFalse() {
        XCTAssertFalse(
            AudiobookLoader.hasRefreshableCredentials(
                username: nil,
                pin: "1234",
                tokenURL: validTokenURL
            ),
            "nil username must short-circuit before tokenURL is consulted"
        )
    }

    func testHasRefreshableCredentials_emptyUsername_returnsFalse() {
        XCTAssertFalse(
            AudiobookLoader.hasRefreshableCredentials(
                username: "",
                pin: "1234",
                tokenURL: validTokenURL
            ),
            "Empty-string username is just as bad as nil — the `!username.isEmpty` guard must reject"
        )
    }

    func testHasRefreshableCredentials_nilPin_returnsFalse() {
        XCTAssertFalse(
            AudiobookLoader.hasRefreshableCredentials(
                username: "alice",
                pin: nil,
                tokenURL: validTokenURL
            ),
            "nil PIN must drop to .missingCredentialsForTokenRefresh"
        )
    }

    func testHasRefreshableCredentials_emptyPin_returnsFalse() {
        XCTAssertFalse(
            AudiobookLoader.hasRefreshableCredentials(
                username: "alice",
                pin: "",
                tokenURL: validTokenURL
            ),
            "Empty-string PIN must be rejected by the `!pin.isEmpty` guard"
        )
    }

    // MARK: - looksLikeHTMLResponse

    private func htmlResponse(contentType: String) -> HTTPURLResponse {
        return HTTPURLResponse(
            url: URL(string: "https://library.test/manifest.json")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
    }

    /// `text/html` Content-Type — the exact shape a login-redirect response
    /// arrives in. The diagnostic-log branch must fire so the message
    /// "Server returned HTML instead of JSON" surfaces in the logs.
    ///
    /// This is the kill point for the line 372 mutation (`== true` → `!= true`):
    /// original returns `true`, mutant returns `false`. `XCTAssertTrue` fails
    /// the mutant.
    func testLooksLikeHTMLResponse_textHTML_returnsTrue() {
        XCTAssertTrue(
            AudiobookLoader.looksLikeHTMLResponse(htmlResponse(contentType: "text/html")),
            "Content-Type 'text/html' must classify as HTML — kill point for the line 372 mutation"
        )
    }

    /// `text/html; charset=utf-8` — the more common real-world shape, with
    /// a charset suffix. The `contains("html")` check must still pick it up.
    func testLooksLikeHTMLResponse_textHTMLWithCharset_returnsTrue() {
        XCTAssertTrue(
            AudiobookLoader.looksLikeHTMLResponse(htmlResponse(contentType: "text/html; charset=utf-8")),
            "Content-Type with charset suffix must still classify as HTML"
        )
    }

    /// `application/xhtml+xml` — XHTML also contains the substring "html"
    /// and is also a redirect-page indicator. Pin behaviour explicitly so
    /// a future "tighten to text/html only" change has to update the test.
    func testLooksLikeHTMLResponse_xhtml_returnsTrue() {
        XCTAssertTrue(
            AudiobookLoader.looksLikeHTMLResponse(htmlResponse(contentType: "application/xhtml+xml")),
            "XHTML Content-Type must also classify as HTML — the contains('html') check is intentionally permissive"
        )
    }

    /// `application/json` — the legitimate manifest path. Must NOT trip
    /// the HTML branch. Companion negative case so the predicate's
    /// TRUE/FALSE bifurcation is fully pinned.
    func testLooksLikeHTMLResponse_applicationJSON_returnsFalse() {
        XCTAssertFalse(
            AudiobookLoader.looksLikeHTMLResponse(htmlResponse(contentType: "application/json")),
            "JSON manifests must NOT fall into the HTML diagnostic branch"
        )
    }

    /// No Content-Type header at all — defensive case. Most well-behaved
    /// servers send one, but a misconfigured proxy may strip it. Must
    /// safely return false, not trap.
    func testLooksLikeHTMLResponse_noContentTypeHeader_returnsFalse() {
        let response = HTTPURLResponse(
            url: URL(string: "https://library.test/manifest.json")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        XCTAssertFalse(
            AudiobookLoader.looksLikeHTMLResponse(response),
            "Missing Content-Type must not crash — must safely return false"
        )
    }
}
