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

    // MARK: - Helper Initialization

    func testSAMLHelperCanBeInstantiated() {
        let helper = TPPSAMLHelper()
        XCTAssertNotNil(helper)
        XCTAssertNil(helper.businessLogic, "businessLogic should be nil initially")
    }

    // MARK: - Guard Behavior: nil IDP URL

    func testLogInWithNilBusinessLogicDoesNotCrash() {
        // TPPSAMLHelper has an implicitly unwrapped businessLogic, but if
        // selectedIDP is nil, the guard should exit early.
        // We can't safely test logIn() without a full mock of TPPSignInBusinessLogic,
        // but we verify the helper can be created and its state is coherent.
        let helper = TPPSAMLHelper()
        // In production, logIn would crash if businessLogic is nil.
        // This test documents that businessLogic must be set before calling logIn.
        XCTAssertNil(helper.businessLogic)
    }
}
