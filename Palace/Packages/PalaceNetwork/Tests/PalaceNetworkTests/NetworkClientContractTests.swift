//
//  NetworkClientContractTests.swift
//  PalaceNetworkTests
//
//  Contract tests for NetworkClient.swift public types. The HTTPMethod
//  rawValue assertions in particular protect against silent rename — these
//  strings go on the wire as request method verbs, and a typo here would
//  silently break every HTTP call across the app.
//

import XCTest
@testable import PalaceNetwork

final class NetworkClientContractTests: XCTestCase {

    // MARK: - HTTPMethod.rawValue (wire-format contract)

    func testHTTPMethod_GET_RawValueIsExactlyGET() {
        XCTAssertEqual(HTTPMethod.GET.rawValue, "GET",
                       "HTTPMethod.GET goes on the wire as the request verb. Renaming it silently breaks every GET request.")
    }

    func testHTTPMethod_POST_RawValueIsExactlyPOST() {
        XCTAssertEqual(HTTPMethod.POST.rawValue, "POST")
    }

    func testHTTPMethod_PUT_RawValueIsExactlyPUT() {
        XCTAssertEqual(HTTPMethod.PUT.rawValue, "PUT")
    }

    func testHTTPMethod_PATCH_RawValueIsExactlyPATCH() {
        XCTAssertEqual(HTTPMethod.PATCH.rawValue, "PATCH")
    }

    func testHTTPMethod_DELETE_RawValueIsExactlyDELETE() {
        XCTAssertEqual(HTTPMethod.DELETE.rawValue, "DELETE")
    }

    func testHTTPMethod_HEAD_RawValueIsExactlyHEAD() {
        XCTAssertEqual(HTTPMethod.HEAD.rawValue, "HEAD")
    }

    /// Round-trip: every rawValue must map back to the same case via init?(rawValue:).
    /// Catches a refactor that, say, changes a raw string literal but forgets one site.
    func testHTTPMethod_RawValueRoundTrip_EveryCase() {
        let allCases: [HTTPMethod] = [.GET, .POST, .PUT, .PATCH, .DELETE, .HEAD]
        for method in allCases {
            let roundTripped = HTTPMethod(rawValue: method.rawValue)
            XCTAssertEqual(roundTripped, method,
                           "rawValue '\(method.rawValue)' must round-trip back to .\(method)")
        }
    }

    // MARK: - NetworkRequest defaults

    func testNetworkRequest_Init_DefaultsHeadersToEmpty() {
        let request = NetworkRequest(method: .GET, url: URL(string: "https://example.com")!)
        XCTAssertEqual(request.headers, [:],
                       "headers must default to [:] so callers don't accidentally inherit nil-vs-empty footguns")
    }

    func testNetworkRequest_Init_DefaultsBodyToNil() {
        let request = NetworkRequest(method: .GET, url: URL(string: "https://example.com")!)
        XCTAssertNil(request.body,
                     "body must default to nil for verbs that don't carry a body (GET, HEAD)")
    }

    func testNetworkRequest_Init_PreservesExplicitHeaders() {
        let headers = ["Authorization": "Bearer xyz", "Accept": "application/json"]
        let request = NetworkRequest(method: .POST,
                                     url: URL(string: "https://example.com")!,
                                     headers: headers,
                                     body: Data("payload".utf8))
        XCTAssertEqual(request.headers, headers,
                       "Explicit headers must round-trip through init unchanged")
        XCTAssertEqual(request.body, Data("payload".utf8))
        XCTAssertEqual(request.method, .POST)
    }

    // MARK: - NetworkResponse construction

    func testNetworkResponse_Init_PreservesDataAndResponse() {
        let url = URL(string: "https://example.com")!
        let httpResponse = HTTPURLResponse(url: url,
                                           statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
        let payload = Data("{\"ok\":true}".utf8)
        let response = NetworkResponse(data: payload, response: httpResponse)
        XCTAssertEqual(response.data, payload)
        XCTAssertEqual(response.response.statusCode, 200)
        XCTAssertEqual(response.response.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
}
