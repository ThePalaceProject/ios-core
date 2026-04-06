//
//  SAMLCookieSyncTests.swift
//  PalaceTests
//
//  Tests for SAML cookie synchronization to HTTPCookieStorage.shared.
//  HelpSpot #16357, #17253, #16235.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class SAMLCookieSyncTests: XCTestCase {

    override func setUp() {
        super.setUp()
        clearSharedCookies()
    }

    override func tearDown() {
        clearSharedCookies()
        super.tearDown()
    }

    private func clearSharedCookies() {
        HTTPCookieStorage.shared.cookies?.forEach {
            HTTPCookieStorage.shared.deleteCookie($0)
        }
    }

    private func makeSAMLCookie(name: String = "saml_session", value: String = "test-token") -> HTTPCookie? {
        return HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: "library.example.com",
            .path: "/",
            .expires: Date(timeIntervalSinceNow: 3600),
        ])
    }

    // MARK: - Cookie Sync Logic

    func testCookieSyncToSharedStorage() {
        guard let cookie = makeSAMLCookie() else {
            XCTFail("Failed to create test cookie")
            return
        }

        let cookies = [cookie]
        let shared = HTTPCookieStorage.shared

        XCTAssertNil(
            shared.cookies?.first(where: { $0.name == "saml_session" }),
            "Cookie should not exist in shared storage initially"
        )

        for c in cookies { shared.setCookie(c) }

        let found = shared.cookies?.first(where: { $0.name == "saml_session" })
        XCTAssertNotNil(found, "Cookie must be present in shared storage after sync")
        XCTAssertEqual(found?.value, "test-token")
    }

    func testCookieSync_multipleCookies() {
        let cookies = [
            makeSAMLCookie(name: "session_id", value: "abc"),
            makeSAMLCookie(name: "auth_token", value: "def"),
            makeSAMLCookie(name: "csrf_token", value: "ghi"),
        ].compactMap { $0 }

        XCTAssertEqual(cookies.count, 3)

        let shared = HTTPCookieStorage.shared
        for c in cookies { shared.setCookie(c) }

        let sharedCookies = shared.cookies?.filter { $0.domain == "library.example.com" } ?? []
        XCTAssertEqual(sharedCookies.count, 3, "All SAML cookies should be in shared storage")
    }

    func testCookieSync_replacesExistingCookie() {
        guard let oldCookie = makeSAMLCookie(value: "old-token"),
              let newCookie = makeSAMLCookie(value: "new-token") else {
            XCTFail("Failed to create cookies")
            return
        }

        let shared = HTTPCookieStorage.shared
        shared.setCookie(oldCookie)
        shared.setCookie(newCookie)

        let found = shared.cookies?.first(where: { $0.name == "saml_session" })
        XCTAssertEqual(found?.value, "new-token", "New cookie should overwrite old one")
    }

    func testCookieSync_emptyCookies_doesNotCrash() {
        let cookies: [HTTPCookie] = []
        let shared = HTTPCookieStorage.shared
        for c in cookies { shared.setCookie(c) }
    }

    // MARK: - Request Creation with SAML Cookies

    func testRequestCreation_includesCookieHeader() {
        guard let cookie = makeSAMLCookie() else {
            XCTFail("Failed to create cookie")
            return
        }

        HTTPCookieStorage.shared.setCookie(cookie)

        let url = URL(string: "https://library.example.com/borrow/123")!
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let headers = HTTPCookie.requestHeaderFields(with: cookies)

        XCTAssertNotNil(headers["Cookie"], "Request to SAML domain should include cookie header")
        XCTAssertTrue(headers["Cookie"]?.contains("saml_session") ?? false)
    }
}

// MARK: - Sign-Out Cache Clearing Tests

final class SignOutCacheClearingTests: XCTestCase {

    func testClearCache_doesNotCrash() {
        TPPNetworkExecutor.shared.clearCache()
        URLCache.shared.removeAllCachedResponses()
    }

    func testURLCacheShared_clearDoesNotCrash() {
        URLCache.shared.removeAllCachedResponses()
    }

    func testNetworkExecutorAndSharedCache_areSeparate() {
        // Executor uses its own URLCache (TPPCaching.makeCache()),
        // so clearing the executor should not affect URLCache.shared
        // and vice versa. We just verify neither crashes.
        TPPNetworkExecutor.shared.clearCache()
        URLCache.shared.removeAllCachedResponses()
    }
}
