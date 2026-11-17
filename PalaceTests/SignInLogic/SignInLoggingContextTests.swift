//
//  SignInLoggingContextTests.swift
//  PalaceTests
//
//  PP-5381: what a failed sign-in reports to Crashlytics.
//

import XCTest
import PalaceUtilities
@testable import Palace

final class SignInLoggingContextTests: XCTestCase {

    private let barcode = "23333012345678"
    private let pin = "9876"

    private func basicAuthSignInRequest() throws -> URLRequest {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://library.example.org/patrons/me/")))
        let credential = Data("\(barcode):\(pin)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Crash reports must not carry the patron's barcode in any form, raw, hashed or encoded.
    func testSignInLoggingContext_WithBasicAuthRequest_ContainsNoFormOfTheBarcode() throws {
        let request = try basicAuthSignInRequest()

        let context = TPPSignInBusinessLogic.signInLoggingContext(request: request, uiContext: "Settings")

        let forbidden = [
            barcode,
            barcode.md5hex(),
            Data("\(barcode):\(pin)".utf8).base64EncodedString()
        ]
        for (key, value) in context {
            let text = "\(value)"
            for needle in forbidden {
                XCTAssertFalse(text.contains(needle), "\(key) carries a form of the patron barcode")
            }
        }
    }

    /// The request line and the screen that started sign-in are still reported for triage.
    func testSignInLoggingContext_KeepsRequestAndContextForTriage() throws {
        let request = try basicAuthSignInRequest()

        let context = TPPSignInBusinessLogic.signInLoggingContext(request: request, uiContext: "Settings")

        XCTAssertEqual(Set(context.keys), ["Request", "Context"])
        XCTAssertEqual(context["Context"] as? String, "Settings")
        let requestLine = try XCTUnwrap(context["Request"] as? String)
        XCTAssertTrue(requestLine.contains("https://library.example.org/patrons/me/"))
        XCTAssertTrue(requestLine.contains("application/json"))
    }
}

final class OAuthRedirectLoggingTests: XCTestCase {

    /// The redirect's fragment carries the access token and patron info; the logged form must drop both.
    func testLoggableRedirectURL_WithTokenAndPatronInFragment_KeepsOnlyHostAndPath() throws {
        let patron = #"{"name":"Ada Patron","barcode":"23333012345678"}"#
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = try XCTUnwrap(URL(string:
            "https://user:pass@example.com/universal-link-redirect?state=abc#access_token=secret-token-value&patron_info=\(patron)"))

        let logged = TPPSignInBusinessLogic.loggableRedirectURL(url)

        XCTAssertEqual(logged, "https://example.com/universal-link-redirect")
        for needle in ["secret-token-value", "Ada", "23333012345678", "state=abc", "user", "pass"] {
            XCTAssertFalse(logged.contains(needle), "the logged redirect URL carries \(needle)")
        }
    }

    /// A failed redirect reports the URL's safe form and the payload's key names, never its values.
    func testRedirectFailureMetadata_WithTokenAndPatronPayload_CarriesNoPayloadValues() throws {
        let url = try XCTUnwrap(URL(string:
            "https://example.com/universal-link-redirect#access_token=secret-token-value&patron_info=Ada%20Patron"))

        let metadata = TPPSignInBusinessLogic.redirectFailureMetadata(
            url: url, payloadKeys: ["patron_info", "access_token"], context: "Settings")

        XCTAssertEqual(Set(metadata.keys), ["redirectURL", "payloadKeys", "context"])
        XCTAssertEqual(metadata["redirectURL"] as? String, "https://example.com/universal-link-redirect")
        XCTAssertEqual(metadata["payloadKeys"] as? String, "access_token, patron_info")
        XCTAssertEqual(metadata["context"] as? String, "Settings")
        for (key, value) in metadata {
            for needle in ["secret-token-value", "Ada"] {
                XCTAssertFalse("\(value)".contains(needle), "\(key) carries \(needle)")
            }
        }
    }

    /// With no parsed payload yet, the report has no payloadKeys entry.
    func testRedirectFailureMetadata_WithoutPayloadKeys_OmitsTheEntry() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/other#access_token=secret-token-value"))

        let metadata = TPPSignInBusinessLogic.redirectFailureMetadata(url: url, payloadKeys: nil, context: "N/A")

        XCTAssertEqual(Set(metadata.keys), ["redirectURL", "context"])
        XCTAssertEqual(metadata["redirectURL"] as? String, "https://example.com/other")
    }
}
