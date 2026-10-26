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
