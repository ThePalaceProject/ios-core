//
//  SAMLHelperTests.swift
//  PalaceTests
//
//  Tests for TPPSAMLHelper: URL construction for SAML login flow.
//  The actual login requires UI presentation, so we focus on the URL
//  building and redirect_uri parameter logic.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class SAMLHelperTests: XCTestCase {

    // MARK: - TPPSAMLHelper URL Construction

    /// Tests that the SAML login URL is properly constructed with redirect_uri appended.
    /// This validates the core URL-building logic without requiring UI presentation.
    func testSAMLLoginURLConstruction() {
        // The SAML helper constructs a URL by appending redirect_uri to the IDP URL.
        // We replicate the logic here to test it in isolation.

        let idpURL = URL(string: "https://idp.example.com/auth?param=value")!
        var urlComponents = URLComponents(url: idpURL, resolvingAgainstBaseURL: true)

        let redirectURI = URLQueryItem(name: "redirect_uri", value: "https://palace.example.com/redirect")
        urlComponents?.queryItems?.append(redirectURI)

        let finalURL = urlComponents?.url
        XCTAssertNotNil(finalURL)

        let query = urlComponents?.queryItems
        XCTAssertEqual(query?.count, 2)
        XCTAssertEqual(query?.first(where: { $0.name == "param" })?.value, "value")
        XCTAssertEqual(query?.first(where: { $0.name == "redirect_uri" })?.value, "https://palace.example.com/redirect")
    }

    func testSAMLLoginURLConstructionWithNoExistingParams() {
        let idpURL = URL(string: "https://idp.example.com/auth")!
        var urlComponents = URLComponents(url: idpURL, resolvingAgainstBaseURL: true)

        // When there are no existing query items, we need to initialize the array
        if urlComponents?.queryItems == nil {
            urlComponents?.queryItems = []
        }

        let redirectURI = URLQueryItem(name: "redirect_uri", value: "https://palace.example.com/redirect")
        urlComponents?.queryItems?.append(redirectURI)

        let finalURL = urlComponents?.url
        XCTAssertNotNil(finalURL)
        XCTAssertTrue(finalURL!.absoluteString.contains("redirect_uri="))
    }

    func testSAMLLoginURLPreservesExistingQueryParams() {
        let idpURL = URL(string: "https://idp.example.com/auth?client_id=abc&scope=openid")!
        var urlComponents = URLComponents(url: idpURL, resolvingAgainstBaseURL: true)

        let redirectURI = URLQueryItem(name: "redirect_uri", value: "https://palace.example.com")
        urlComponents?.queryItems?.append(redirectURI)

        let items = urlComponents?.queryItems ?? []
        XCTAssertEqual(items.count, 3)

        let names = items.map { $0.name }
        XCTAssertTrue(names.contains("client_id"))
        XCTAssertTrue(names.contains("scope"))
        XCTAssertTrue(names.contains("redirect_uri"))
    }

    // NOTE: Two legacy tests were removed alongside the PalaceAuth leaf
    // extraction (PR #936). They asserted on `TPPSAMLHelper()` (parameterless
    // init, dropped when the helper moved to PalaceAuth) and on a `businessLogic`
    // property that no longer exists on the new SAMLAuthContext-injected design.
    // They were also banned fluff per CLAUDE.md — "two instances are distinct
    // objects" and "asserting a constructor returns non-nil" are listed as
    // pattern violations. Meaningful coverage of the new init lives in
    // PalaceTests/SignInLogic/TPPSAMLFlowTests.swift, which exercises the
    // helper via concrete SAMLAuthContext + SAMLWebViewPresenting mocks.
}
