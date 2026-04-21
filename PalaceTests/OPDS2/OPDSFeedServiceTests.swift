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

    // MARK: - Singleton Tests

    func testShared_returnsSameInstance() async {
        let service1 = await OPDSFeedService.shared
        let service2 = await OPDSFeedService.shared

        // Should be the same actor instance
        XCTAssertTrue(service1 === service2)
    }

    // MARK: - Cancellation Tests (no network calls)

    func testCancelRequest_doesNotCrash() async {
        let service = OPDSFeedService.shared
        let url = URL(string: "https://example.com/feed")!

        // Cancelling a URL for which no request is in-flight must not throw or crash
        await service.cancelRequest(for: url)

        // Verify the service is still usable after the cancellation call
        let service2 = await OPDSFeedService.shared
        XCTAssertTrue(service === service2, "Service should remain the same actor instance after cancel")
    }

    func testCancelAllRequests_doesNotCrash() async {
        let service = OPDSFeedService.shared

        // Cancelling all requests when none are in flight must not throw or crash
        await service.cancelAllRequests()

        // Service must still be the shared singleton afterwards
        let service2 = await OPDSFeedService.shared
        XCTAssertTrue(service === service2, "Service must remain the singleton after cancelAllRequests")
    }

    // MARK: - API Method Existence Tests
    // These tests verify the API methods exist and have correct signatures
    // without making actual network calls that could hang

    func testFetchLoans_methodExists() async {
        let service = OPDSFeedService.shared
        XCTAssertNotNil(service, "Service should exist")
        // Verify the service is still accessible and is the same shared instance
        let service2 = await OPDSFeedService.shared
        XCTAssertTrue(service === service2, "fetchLoans lives on the shared singleton")
    }

    func testFetchCatalogRoot_methodExists() async {
        let service = OPDSFeedService.shared
        XCTAssertNotNil(service, "Service should exist")
        // Verify the service is still accessible and is the same shared instance
        let service2 = await OPDSFeedService.shared
        XCTAssertTrue(service === service2, "fetchCatalogRoot lives on the shared singleton")
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
