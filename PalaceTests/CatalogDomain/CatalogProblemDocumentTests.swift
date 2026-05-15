//
//  CatalogProblemDocumentTests.swift
//  PalaceTests
//
//  Pinning tests for Gap 4: When the catalog server returns a response with
//  Content-Type `application/problem+json` (RFC 7807), the parser must surface
//  the structured fields via `ParserError.problemDocument(_:)` instead of
//  funneling the body through the generic JSON parser and emitting the opaque
//  `ParserError.invalidJSON`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class CatalogProblemDocumentTests: XCTestCase {

    // MARK: - Properties

    private var networkClient: NetworkClientMock!
    private var parser: OPDSParser!
    private var api: DefaultCatalogAPI!

    private let feedURL = URL(string: "https://library.example.com/groups/")!

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        networkClient = NetworkClientMock()
        parser = OPDSParser()
        api = DefaultCatalogAPI(client: networkClient, parser: parser)
    }

    override func tearDown() {
        networkClient = nil
        parser = nil
        api = nil
        super.tearDown()
    }

    // MARK: - Parser-level pinning

    func testParser_problemJSONContentType_throwsProblemDocumentErrorNotInvalidJSON() {
        let json = """
        {
          "type": "https://example.com/problems/loan-limit",
          "title": "Loan Limit Reached",
          "status": 403,
          "detail": "You have reached your maximum number of loans."
        }
        """
        let data = Data(json.utf8)

        XCTAssertThrowsError(
            try parser.parseFeed(from: data, contentType: "application/problem+json")
        ) { error in
            guard let parserError = error as? OPDSParser.ParserError else {
                XCTFail("Expected OPDSParser.ParserError, got \(error)")
                return
            }
            // Critical: must NOT be the generic invalidJSON case.
            switch parserError {
            case .invalidJSON:
                XCTFail("Problem document leaked through as generic invalidJSON — caller loses title/detail.")
            case .problemDocument(let doc):
                XCTAssertEqual(doc.title, "Loan Limit Reached")
                XCTAssertEqual(doc.detail, "You have reached your maximum number of loans.")
                XCTAssertEqual(doc.status, 403)
                XCTAssertEqual(doc.type, "https://example.com/problems/loan-limit")
            default:
                XCTFail("Unexpected parser error: \(parserError)")
            }
        }
    }

    func testParser_problemJSONContentType_errorDescriptionIncludesTitleAndDetail() {
        let json = """
        { "title": "Server Unavailable", "detail": "Try again in 60 seconds.", "status": 503 }
        """
        let data = Data(json.utf8)

        XCTAssertThrowsError(
            try parser.parseFeed(from: data, contentType: "application/problem+json")
        ) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(description.contains("Server Unavailable"),
                          "Description should include problem title; got: \(description)")
            XCTAssertTrue(description.contains("Try again in 60 seconds."),
                          "Description should include problem detail; got: \(description)")
        }
    }

    /// Tolerate Content-Type parameters (charset, profile, etc.).
    func testParser_problemJSONContentTypeWithCharset_stillDetected() {
        let json = """
        { "title": "Borrow Failed", "detail": "Already on loan." }
        """
        let data = Data(json.utf8)

        XCTAssertThrowsError(
            try parser.parseFeed(from: data, contentType: "application/problem+json; charset=utf-8")
        ) { error in
            guard case OPDSParser.ParserError.problemDocument(let doc) = error else {
                XCTFail("Expected problemDocument, got \(error)")
                return
            }
            XCTAssertEqual(doc.title, "Borrow Failed")
            XCTAssertEqual(doc.detail, "Already on loan.")
        }
    }

    /// Without the problem content-type, a plain JSON body must still fall through
    /// to the OPDS2 path (or invalidJSON if malformed) — the new branch must not
    /// hijack regular JSON responses.
    func testParser_plainJSONContentType_doesNotTriggerProblemDocumentPath() {
        let json = """
        { "title": "Looks Like Problem But Isn't" }
        """
        let data = Data(json.utf8)

        XCTAssertThrowsError(
            try parser.parseFeed(from: data, contentType: "application/json")
        ) { error in
            guard let parserError = error as? OPDSParser.ParserError else {
                XCTFail("Expected ParserError, got \(error)")
                return
            }
            if case .problemDocument = parserError {
                XCTFail("application/json must not be treated as a problem document")
            }
            // .invalidJSON is the expected fall-through for a malformed OPDS2 body.
            XCTAssertEqual(parserError, .invalidJSON)
        }
    }

    /// Body that's not decodable as a valid problem document must still produce
    /// a structured problemDocument error (synthesized) rather than invalidJSON.
    func testParser_undecodableProblemBody_stillSurfacesAsProblemDocument() {
        let garbage = Data("not actually json".utf8)

        XCTAssertThrowsError(
            try parser.parseFeed(from: garbage, contentType: "application/problem+json")
        ) { error in
            guard case OPDSParser.ParserError.problemDocument = error else {
                XCTFail("Even a bad problem body should surface as .problemDocument, got \(error)")
                return
            }
        }
    }

    // MARK: - End-to-end (CatalogAPI → parser) pinning

    /// Server returns 503 with `Content-Type: application/problem+json` — caller
    /// receives a `ParserError.problemDocument` carrying title/detail/status/type.
    func testFetchFeed_503ProblemDocument_surfacesStructuredErrorThroughAPI() async {
        let json = """
        {
          "type": "https://example.com/problems/maintenance",
          "title": "Service Unavailable",
          "status": 503,
          "detail": "The catalog is undergoing maintenance. Try again later."
        }
        """
        let httpResponse = HTTPURLResponse(
            url: feedURL,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/problem+json"]
        )!
        networkClient.stubbedResponses[feedURL] = NetworkResponse(
            data: Data(json.utf8), response: httpResponse
        )

        do {
            _ = try await api.fetchFeed(at: feedURL)
            XCTFail("Expected ParserError.problemDocument to be thrown")
        } catch let OPDSParser.ParserError.problemDocument(doc) {
            XCTAssertEqual(doc.status, 503)
            XCTAssertEqual(doc.title, "Service Unavailable")
            XCTAssertEqual(doc.detail, "The catalog is undergoing maintenance. Try again later.")
            XCTAssertEqual(doc.type, "https://example.com/problems/maintenance")
        } catch {
            XCTFail("Expected ParserError.problemDocument, got \(error)")
        }
    }
}
