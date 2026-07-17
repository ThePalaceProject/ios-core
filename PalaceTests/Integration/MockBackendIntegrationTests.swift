//
//  MockBackendIntegrationTests.swift
//  PalaceTests
//
//  Integration tests that exercise real app code against the mock backend.
//  Uses MockBackendTestHelper for clean one-line setup.
//

import XCTest
import PalaceCatalog
@testable import Palace

// MARK: - Happy Path

@MainActor
final class MockBackendIntegrationTests: XCTestCase {

    private var env: MockBackendEnvironment!
    private let baseURL = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/")!

    override func setUp() async throws {
        try await super.setUp()
        env = try MockBackendTestHelper.activate(scenario: "happy_path")
    }

    override func tearDown() {
        MockBackendTestHelper.deactivate()
        env = nil
        super.tearDown()
    }

    func testFetchCatalog_ReturnsParsedFeed() async throws {
        let feed = try await env.fetchFeed(at: baseURL)
        XCTAssertEqual(feed.title, "A1QA Test Library")
        // OPDS2 feeds may have entries from publications OR groups
        XCTAssertNotNil(feed.opds2Feed, "Feed must have OPDS2 source data")
        let hasContent = !feed.entries.isEmpty ||
                         !(feed.opds2Feed?.publications?.isEmpty ?? true) ||
                         !(feed.opds2Feed?.groups?.isEmpty ?? true)
        XCTAssertTrue(hasContent, "Feed must have entries, publications, or groups")
    }

    func testFetchAnnotations_ReturnsAnnotations() async throws {
        let url = baseURL.appendingPathComponent("annotations")
        let json = try await env.fetchJSON(at: url)
        XCTAssertEqual(json["total"] as? Int, 2)
    }

    func testFetchAuthDocument_ParsesCorrectly() async throws {
        let url = baseURL.appendingPathComponent("authentication_document")
        let json = try await env.fetchJSON(at: url)
        XCTAssertEqual(json["title"] as? String, "A1QA Test Library")
        let methods = json["authentication"] as? [[String: Any]]
        XCTAssertGreaterThanOrEqual(methods?.count ?? 0, 1)
    }

    func testBorrow_Returns201() async throws {
        let url = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/works/book-123/borrow")!
        let (_, status) = try await env.fetchWithStatus(url, method: "POST")
        XCTAssertEqual(status, 201)
    }
}

// MARK: - Expired Credentials

@MainActor
final class MockBackendExpiredCredentialsTests: XCTestCase {

    private var env: MockBackendEnvironment!

    override func setUp() async throws {
        try await super.setUp()
        env = try MockBackendTestHelper.activate(scenario: "expired_credentials")
    }

    override func tearDown() {
        MockBackendTestHelper.deactivate()
        env = nil
        super.tearDown()
    }

    func testCatalog_StillReturns200() async throws {
        let url = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/")!
        let (_, status) = try await env.fetchWithStatus(url)
        XCTAssertEqual(status, 200)
    }

    func testLoans_Returns403WithProblemDocument() async throws {
        let url = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/loans")!
        let (data, status) = try await env.fetchWithStatus(url)

        XCTAssertEqual(status, 403)
        let doc = try JSONDecoder().decode(TPPProblemDocument.self, from: data)
        XCTAssertTrue(doc.type?.contains("expired") ?? false)
    }

    func testBorrow_Returns403() async throws {
        let url = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/works/book-123/borrow")!
        let (_, status) = try await env.fetchWithStatus(url, method: "POST")
        XCTAssertEqual(status, 403)
    }
}

// MARK: - Loan Limit

@MainActor
final class MockBackendLoanLimitTests: XCTestCase {

    private var env: MockBackendEnvironment!

    override func setUp() async throws {
        try await super.setUp()
        env = try MockBackendTestHelper.activate(scenario: "loan_limit")
    }

    override func tearDown() {
        MockBackendTestHelper.deactivate()
        env = nil
        super.tearDown()
    }

    func testBorrow_Returns403WithLoanLimitProblem() async throws {
        let url = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/works/book-123/borrow")!
        let (data, status) = try await env.fetchWithStatus(url, method: "POST")

        XCTAssertEqual(status, 403)
        let doc = try JSONDecoder().decode(TPPProblemDocument.self, from: data)
        XCTAssertTrue(doc.type?.contains("loan-limit") ?? false)
        XCTAssertTrue(doc.detail?.lowercased().contains("return") ?? false)
    }

    func testCatalogBrowsing_StillWorks() async throws {
        let url = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/")!
        let feed = try await env.fetchFeed(at: url)
        XCTAssertEqual(feed.title, "A1QA Test Library")
    }
}

// MARK: - Server Down

@MainActor
final class MockBackendServerDownTests: XCTestCase {

    private var env: MockBackendEnvironment!

    override func setUp() async throws {
        try await super.setUp()
        env = try MockBackendTestHelper.activate(scenario: "server_down")
    }

    override func tearDown() {
        MockBackendTestHelper.deactivate()
        env = nil
        super.tearDown()
    }

    func testAllEndpoints_Return502() async throws {
        let urls = [
            URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/")!,
            URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/loans")!,
            URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/annotations")!,
        ]

        for url in urls {
            let (data, status) = try await env.fetchWithStatus(url)
            XCTAssertEqual(status, 502, "\(url.path) should return 502")

            let doc = try JSONDecoder().decode(TPPProblemDocument.self, from: data)
            XCTAssertTrue(doc.type?.contains("remote-integration-failed") ?? false)
        }
    }
}

// MARK: - Route Matching Unit Tests

@MainActor
final class MockBackendRouteMatchingTests: XCTestCase {

    func testRouteMatching_ExactPath() {
        let route = MockRoute(pathPattern: ".*/loans.*", fixtureName: "opds2_feed", statusCode: 200, contentType: "application/json")

        var request = URLRequest(url: URL(string: "https://example.com/a1qa-test/loans")!)
        XCTAssertTrue(route.matches(request))

        request = URLRequest(url: URL(string: "https://example.com/a1qa-test/catalog")!)
        XCTAssertFalse(route.matches(request))
    }

    func testRouteMatching_MethodFilter() {
        let postRoute = MockRoute(method: "POST", pathPattern: ".*/borrow", fixtureName: "opds2_feed", statusCode: 201, contentType: "application/json")

        var request = URLRequest(url: URL(string: "https://example.com/borrow")!)
        request.httpMethod = "POST"
        XCTAssertTrue(postRoute.matches(request))

        request.httpMethod = "GET"
        XCTAssertFalse(postRoute.matches(request))
    }

    func testRouteMatching_CatchAll() {
        let catchAll = MockRoute(pathPattern: ".*", fixtureName: "opds2_feed", statusCode: 200, contentType: "application/json")
        let request = URLRequest(url: URL(string: "https://anything.com/any/path")!)
        XCTAssertTrue(catchAll.matches(request))
    }

    func testScenarioLoading() throws {
        let env = try MockBackendTestHelper.activate(scenario: "happy_path")
        defer { MockBackendTestHelper.deactivate() }

        XCTAssertEqual(env.scenario.id, "happy_path")
        XCTAssertGreaterThanOrEqual(env.scenario.routes.count, 5)
    }
}

// MARK: - Holds (Reserved + Ready)

/// Exercises the `holds_reserved` scenario: the mock backend serves a
/// loans/holds feed with one reserved hold (queue position 3 of 8) plus one
/// ready-to-borrow hold, so the populated Holds tab can be tested without real
/// limited-copy inventory.
@MainActor
final class MockBackendHoldsTests: XCTestCase {

    private var env: MockBackendEnvironment!
    private let loansURL = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/loans")!

    override func setUp() async throws {
        try await super.setUp()
        env = try MockBackendTestHelper.activate(scenario: "holds_reserved")
    }

    override func tearDown() {
        MockBackendTestHelper.deactivate()
        env = nil
        super.tearDown()
    }

    func testHoldsScenario_LoansFeed_ServesReservedAndReadyEntries() async throws {
        let (data, status) = try await env.fetchWithStatus(loansURL)
        XCTAssertEqual(status, 200)

        guard let xml = TPPXML.xml(withData: data), let feed = TPPOPDSFeed(xml: xml) else {
            return XCTFail("Holds feed did not parse as OPDS")
        }
        XCTAssertEqual(feed.entries.count, 2)
        XCTAssertEqual(feed.entries[0].title, "The Glass Menagerie Reimagined")
        XCTAssertEqual(feed.entries[1].title, "Quantum Cooking: Science in the Kitchen")
    }

    func testHoldsScenario_ReservedEntry_ExposesQueuePosition() async throws {
        let (data, _) = try await env.fetchWithStatus(loansURL)
        guard let xml = TPPXML.xml(withData: data), let feed = TPPOPDSFeed(xml: xml),
              let reserved = feed.entries.first?.acquisitions.first else {
            return XCTFail("Reserved acquisition missing from holds feed")
        }
        var isReserved = false
        var holdPosition: UInt = 0
        reserved.availability.match(
            unavailable: nil,
            limited: nil,
            unlimited: nil,
            reserved: { isReserved = true; holdPosition = $0.holdPosition },
            ready: nil
        )
        XCTAssertTrue(isReserved, "First hold entry must be reserved (queued)")
        XCTAssertEqual(holdPosition, 3, "Queue position must be 3 of 8")
    }

    func testHoldsScenario_ReadyEntry_HasReadyAvailability() async throws {
        let (data, _) = try await env.fetchWithStatus(loansURL)
        guard let xml = TPPXML.xml(withData: data), let feed = TPPOPDSFeed(xml: xml),
              feed.entries.count >= 2 else {
            return XCTFail("Ready hold entry missing from holds feed")
        }
        var isReady = false
        feed.entries[1].acquisitions[0].availability.match(
            unavailable: nil,
            limited: nil,
            unlimited: nil,
            reserved: nil,
            ready: { _ in isReady = true }
        )
        XCTAssertTrue(isReady, "Second hold entry must be ready-to-borrow")
    }
}
