//
//  AuthErrorProblemDocSeamTests.swift
//  PalaceTests
//
//  Regression guard for PP-3956. Locks in the cross-class contract that every
//  auth-path NSError constructed from an HTTP error body carries the RFC 7807
//  problem document forward to `userFacingSignInError`, so the sign-in UI shows
//  the server-supplied reason (e.g. "Expired Card") rather than the generic
//  "Invalid Credentials" fallback.
//
//  The original TokenRequestTests asserted only the inside-class shape and
//  never exercised this seam — that's why the bug landed in commit 99d67d424
//  (2025-10-09) and survived until Daniel Bernstein caught it in PR #931.
//

import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

@MainActor
class AuthErrorProblemDocSeamTests: XCTestCase {

    private let tokenURL = URL(string: "https://auth.example.com/token")!
    private let problemJSON = """
    {
        "type": "http://librarysimplified.org/terms/problem/expired-credentials",
        "title": "Expired Card",
        "detail": "Your library card has expired.",
        "status": 403
    }
    """

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - NSError.makeFromHTTPResponse — the helper itself

    func testMakeFromHTTPResponse_WithProblemDocBody_EmbedsDoc() {
        let error = NSError.makeFromHTTPResponse(
            data: Data(problemJSON.utf8),
            statusCode: 403,
            domain: "TestDomain")

        XCTAssertEqual(error.code, 403)
        XCTAssertEqual(error.domain, "TestDomain")
        XCTAssertEqual(error.problemDocument?.title, "Expired Card",
                       "Helper must embed the parsed problem document so callers don't have to re-parse")
        XCTAssertEqual(error.problemDocument?.detail, "Your library card has expired.")
    }

    func testMakeFromHTTPResponse_WithNonJSONBody_NoProblemDoc() {
        let error = NSError.makeFromHTTPResponse(
            data: Data("Forbidden".utf8),
            statusCode: 403,
            domain: "TestDomain")

        XCTAssertEqual(error.code, 403)
        XCTAssertNil(error.problemDocument,
                     "Plain-text body must produce a clean error with no problem document")
    }

    func testMakeFromHTTPResponse_PreservesCallerUserInfo() {
        let error = NSError.makeFromHTTPResponse(
            data: Data(problemJSON.utf8),
            statusCode: 403,
            domain: "TestDomain",
            userInfo: [NSLocalizedDescriptionKey: "Caller-supplied description"])

        XCTAssertEqual(error.userInfo[NSLocalizedDescriptionKey] as? String,
                       "Caller-supplied description",
                       "Helper must not stomp on caller-supplied userInfo keys")
        XCTAssertNotNil(error.problemDocument,
                        "Caller userInfo must be merged with — not replace — the problem doc")
    }

    // MARK: - TokenRequest → userFacingSignInError end-to-end seam

    func testTokenRequest_On403WithProblemDoc_FlowsThroughToUserFacingTitle() async {
        HTTPStubURLProtocol.register { [problemJSON, tokenURL] request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 403,
                         headers: ["Content-Type": "application/problem+json"],
                         body: Data(problemJSON.utf8))
        }

        let session = URLSession.stubbedSession()
        let tokenRequest = TokenRequest(url: tokenURL, username: "user", password: "pass")
        let result = await tokenRequest.execute(session: session)

        guard case .failure(let error) = result else {
            XCTFail("Expected failure for 403 response, got \(result)")
            return
        }

        let nsError = error as NSError
        let (title, message) = TPPSignInBusinessLogic.userFacingSignInError(
            for: nsError,
            problemDocument: nsError.problemDocument)

        XCTAssertEqual(title, "Expired Card",
                       "Server-supplied title must reach the sign-in UI, not the generic fallback")
        XCTAssertEqual(message, "Your library card has expired.",
                       "Server-supplied detail must reach the sign-in UI")
    }

    func testTokenRequest_On403WithoutProblemDoc_FallsBackToGenericTitle() async {
        HTTPStubURLProtocol.register { [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 403,
                         headers: ["Content-Type": "text/plain"],
                         body: Data("Forbidden".utf8))
        }

        let session = URLSession.stubbedSession()
        let tokenRequest = TokenRequest(url: tokenURL, username: "user", password: "pass")
        let result = await tokenRequest.execute(session: session)

        guard case .failure(let error) = result else {
            XCTFail("Expected failure for 403 response, got \(result)")
            return
        }

        let nsError = error as NSError
        let (title, _) = TPPSignInBusinessLogic.userFacingSignInError(
            for: nsError,
            problemDocument: nsError.problemDocument)

        XCTAssertNotEqual(title, "Expired Card",
                          "Plain-text body must not synthesize a fake problem doc")
        XCTAssertNil(nsError.problemDocument,
                     "Fallback path must produce a clean error so userFacingSignInError uses its generic strings")
    }

    // MARK: - Re-wrap path preserves problemDocument

    func testRewrappedError_PreservesUpstreamProblemDocument() {
        // Simulates what TPPNetworkExecutor.executeTokenRefresh does after a
        // TokenRequest failure: build a new NSError in the executor's domain
        // while preserving the upstream problem document. This is the
        // information-loss seam Daniel's PR #931 stopped one layer above,
        // and this guard locks in the upstream-to-wrapped propagation.

        let upstream = NSError.makeFromHTTPResponse(
            data: Data(problemJSON.utf8),
            statusCode: 403,
            domain: "TokenRequest")

        guard let upstreamProblemDoc = upstream.problemDocument else {
            XCTFail("Test setup: helper failed to embed problem doc")
            return
        }

        let wrapped = NSError.makeFromProblemDocument(
            upstreamProblemDoc,
            domain: TPPErrorLogger.clientDomain,
            code: TPPErrorCode.invalidCredentials.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Token refresh failed"])

        XCTAssertEqual(wrapped.problemDocument?.title, "Expired Card",
                       "Wrap must preserve the upstream problem document so token-refresh failures show the server-supplied title")
        XCTAssertEqual(wrapped.domain, TPPErrorLogger.clientDomain,
                       "Wrap should still re-domain so existing callers' switch-on-domain logic is unaffected")
        XCTAssertEqual(wrapped.code, TPPErrorCode.invalidCredentials.rawValue,
                       "Wrap should still re-code so existing callers' switch-on-code logic is unaffected")
    }
}
