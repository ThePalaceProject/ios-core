//
//  OPDSFeedServiceTests.swift
//  PalaceTests
//
//  Tests for OPDS feed service - API existence and cancellation tests only.
//  Network-dependent tests are skipped to avoid flakiness and slowdowns.
//

import XCTest
@testable import Palace

final class OPDSFeedServiceTests: XCTestCase {

    // MARK: - Cancellation Tests (no network calls)

    /// Cancelling a URL with no in-flight request should be a no-op rather
    /// than throwing or crashing the actor — UI code calls this opportunistically
    /// (on view disappear, on navigation away) without first checking whether a
    /// fetch is actually active. Idempotency matters because users can dismiss
    /// the same screen multiple times via gestures + system back.
    func testCancelRequest_isNoOpAndIdempotent_whenNoInflightRequestForUrl() async {
        let service = OPDSFeedService()
        let url = URL(string: "https://example.com/feed")!
        let otherURL = URL(string: "https://example.com/other")!

        var awaitedCallsCompleted = 0
        await service.cancelRequest(for: url);      awaitedCallsCompleted += 1
        await service.cancelRequest(for: url);      awaitedCallsCompleted += 1
        await service.cancelRequest(for: otherURL); awaitedCallsCompleted += 1

        XCTAssertEqual(awaitedCallsCompleted, 3,
                       "All three cancellation awaits completed — actor did not crash, hang, or trap")
    }

    func testCancelAllRequests_isNoOpAndIdempotent_whenNothingInFlight() async {
        let service = OPDSFeedService()

        var awaitedCallsCompleted = 0
        await service.cancelAllRequests(); awaitedCallsCompleted += 1
        await service.cancelAllRequests(); awaitedCallsCompleted += 1

        XCTAssertEqual(awaitedCallsCompleted, 2,
                       "Both cancelAll awaits completed — actor did not crash, hang, or trap")
    }

    // MARK: - Problem Document Mapping

    /// SAML session expiry returns a recoverable-auth problem document under the
    /// palaceproject.io namespace. Before this fix, OPDSFeedService only knew
    /// the librarysimplified.org namespace and fell through to .network(.serverError)
    /// or generic .invalidCredentials, hiding the recoverability signal from
    /// callers (loans refresh, /patrons/me/, /annotations/).
    func testParseProblemDocument_recoverableSAMLSessionExpired_returnsTokenExpired() async {
        let dict: [String: Any] = [
            "type": "http://palaceproject.io/terms/problem/auth/recoverable/saml/session-expired",
            "title": "SAML session expired",
            "status": 401
        ]
        let problemDoc = TPPProblemDocument.fromDictionary(dict)
        let service = OPDSFeedService.shared

        let result = await service.parseProblemDocument(problemDoc)

        guard case .authentication(.tokenExpired) = result else {
            XCTFail("Expected .authentication(.tokenExpired) for recoverable SAML, got \(result)")
            return
        }
    }

    func testParseProblemDocument_recoverableTokenExpired_returnsTokenExpired() async {
        let dict: [String: Any] = [
            "type": "http://palaceproject.io/terms/problem/auth/recoverable/token/expired",
            "title": "Token expired",
            "status": 401
        ]
        let problemDoc = TPPProblemDocument.fromDictionary(dict)
        let service = OPDSFeedService.shared

        let result = await service.parseProblemDocument(problemDoc)

        guard case .authentication(.tokenExpired) = result else {
            XCTFail("Expected .authentication(.tokenExpired) for recoverable token, got \(result)")
            return
        }
    }

    func testParseProblemDocument_unrecoverableNoActiveAccount_returnsInvalidCredentials() async {
        let dict: [String: Any] = [
            "type": "http://palaceproject.io/terms/problem/auth/unrecoverable/no-active-account",
            "title": "No active account",
            "status": 403
        ]
        let problemDoc = TPPProblemDocument.fromDictionary(dict)
        let service = OPDSFeedService.shared

        let result = await service.parseProblemDocument(problemDoc)

        guard case .authentication(.invalidCredentials) = result else {
            XCTFail("Expected .authentication(.invalidCredentials) for unrecoverable, got \(result)")
            return
        }
    }

    /// Mutation guard: a truly unrecognised type that is neither recoverable nor
    /// unrecoverable auth must still fall through to the existing HTTP-status mapping.
    /// This catches a regression where the new branches accidentally swallow non-auth
    /// problem documents.
    func testParseProblemDocument_unrecognisedTypeWith404_returnsNetworkNotFound() async {
        let dict: [String: Any] = [
            "type": "http://example.com/problem/something-weird",
            "title": "Something weird",
            "status": 404
        ]
        let problemDoc = TPPProblemDocument.fromDictionary(dict)
        let service = OPDSFeedService.shared

        let result = await service.parseProblemDocument(problemDoc)

        guard case .network(.notFound) = result else {
            XCTFail("Expected .network(.notFound) for unrecognised type with 404, got \(result)")
            return
        }
    }
}

// MARK: - Palace Error Tests

final class PalaceErrorTests: XCTestCase {

    func testPalaceError_parsing_opdsFeedInvalid() {
        let error = PalaceError.parsing(.opdsFeedInvalid)

        XCTAssertNotNil(error)
        // Verify it is recognized as an Error and conforms to LocalizedError
        let asError: Error = error
        XCTAssertTrue(asError is PalaceError)
        XCTAssertFalse(error.localizedDescription.isEmpty, "Parsing error must have a localized description")
    }

    func testPalaceError_network_serverError() {
        let error = PalaceError.network(.serverError)

        XCTAssertNotNil(error)
        XCTAssertTrue(error is PalaceError)
        XCTAssertFalse(error.localizedDescription.isEmpty, "Network error must have a localized description")
        // Verify different network codes produce distinct descriptions
        let forbidden = PalaceError.network(.forbidden)
        XCTAssertNotEqual(error.localizedDescription, forbidden.localizedDescription,
                          "serverError and forbidden should have distinct descriptions")
    }

    func testPalaceError_authentication_invalidCredentials() {
        let error = PalaceError.authentication(.invalidCredentials)

        XCTAssertNotNil(error)
        XCTAssertTrue(error is PalaceError)
        XCTAssertFalse(error.localizedDescription.isEmpty, "Auth error must have a localized description")
        // Verify different auth codes produce distinct descriptions
        let tokenExpired = PalaceError.authentication(.tokenExpired)
        XCTAssertNotEqual(error.localizedDescription, tokenExpired.localizedDescription,
                          "invalidCredentials and tokenExpired should have distinct descriptions")
    }

    func testPalaceError_bookRegistry_bookNotFound() {
        let error = PalaceError.bookRegistry(.bookNotFound)

        XCTAssertNotNil(error)
        XCTAssertTrue(error is PalaceError)
        XCTAssertFalse(error.localizedDescription.isEmpty, "Book registry error must have a localized description")
    }

    func testPalaceError_bookRegistry_alreadyBorrowed() {
        let error = PalaceError.bookRegistry(.alreadyBorrowed)

        XCTAssertNotNil(error)
        XCTAssertTrue(error is PalaceError)
        // bookNotFound and alreadyBorrowed are distinct error cases
        let notFound = PalaceError.bookRegistry(.bookNotFound)
        XCTAssertNotEqual(error.localizedDescription, notFound.localizedDescription,
                          "alreadyBorrowed and bookNotFound should differ")
    }

    func testPalaceError_download_cannotFulfill() {
        let error = PalaceError.download(.cannotFulfill)

        XCTAssertNotNil(error)
        XCTAssertTrue(error is PalaceError)
        XCTAssertFalse(error.localizedDescription.isEmpty, "Download error must have a localized description")
    }

    func testPalaceError_network_forbidden() {
        let error = PalaceError.network(.forbidden)

        XCTAssertNotNil(error)
        XCTAssertTrue(error is PalaceError)
        XCTAssertFalse(error.localizedDescription.isEmpty, "Forbidden error must have a localized description")
    }

    func testPalaceError_network_notFound() {
        let error = PalaceError.network(.notFound)

        XCTAssertNotNil(error)
        XCTAssertTrue(error is PalaceError)
        XCTAssertFalse(error.localizedDescription.isEmpty, "Not-found error must have a localized description")
        // notFound and serverError are distinct
        let serverError = PalaceError.network(.serverError)
        XCTAssertNotEqual(error.localizedDescription, serverError.localizedDescription)
    }

    func testPalaceError_network_rateLimited() {
        let error = PalaceError.network(.rateLimited)

        XCTAssertNotNil(error)
        XCTAssertTrue(error is PalaceError)
        XCTAssertFalse(error.localizedDescription.isEmpty, "Rate-limited error must have a localized description")
    }

    func testPalaceError_authentication_tokenExpired() {
        let error = PalaceError.authentication(.tokenExpired)

        XCTAssertNotNil(error)
        XCTAssertTrue(error is PalaceError)
        XCTAssertFalse(error.localizedDescription.isEmpty, "Token-expired error must have a localized description")
    }

    func testPalaceError_authentication_accountNotFound() {
        let error = PalaceError.authentication(.accountNotFound)

        XCTAssertNotNil(error)
        XCTAssertTrue(error is PalaceError)
        XCTAssertFalse(error.localizedDescription.isEmpty, "Account-not-found error must have a localized description")
        // invalidCredentials and accountNotFound are distinct auth failures
        let invalidCreds = PalaceError.authentication(.invalidCredentials)
        XCTAssertNotEqual(error.localizedDescription, invalidCreds.localizedDescription,
                          "accountNotFound and invalidCredentials should differ")
    }
}
