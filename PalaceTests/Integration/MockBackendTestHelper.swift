//
//  MockBackendTestHelper.swift
//  PalaceTests
//
//  Clean, reusable helper for setting up mock backend scenarios in tests.
//  Any test can activate a scenario in one line and get a fully-configured
//  network executor that exercises real app code against fixture data.
//
//  Usage:
//    let env = try MockBackendTestHelper.activate(scenario: "happy_path")
//    let data = try await env.fetch(url)
//    let feed = try env.parser.parseFeed(from: data)
//



import XCTest
@testable import Palace

/// A test environment with a mock-backed network stack.
/// All real app code runs — only the HTTP layer is intercepted.
struct MockBackendEnvironment {
    let session: URLSession
    let executor: TPPNetworkExecutor
    let parser: OPDSParser
    let scenario: MockScenario

    /// Fetch a URL and return the data + HTTP response.
    func fetch(_ url: URL, method: String = "GET") async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (data, _) = try await session.data(for: request)
        return data
    }

    /// Fetch and return both data and HTTP status code.
    func fetchWithStatus(_ url: URL, method: String = "GET") async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, statusCode)
    }

    /// Convenience: fetch and parse an OPDS feed.
    func fetchFeed(at url: URL) async throws -> CatalogFeed {
        let data = try await fetch(url)
        return try parser.parseFeed(from: data)
    }

    /// Convenience: fetch and parse a problem document.
    func fetchProblemDocument(at url: URL, method: String = "GET") async throws -> TPPProblemDocument {
        let data = try await fetch(url, method: method)
        return try JSONDecoder().decode(TPPProblemDocument.self, from: data)
    }

    /// Convenience: fetch and parse JSON.
    func fetchJSON(at url: URL) async throws -> [String: Any] {
        let data = try await fetch(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MockBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not a JSON object"])
        }
        return json
    }
}

/// Helper for activating mock backend scenarios in tests.
enum MockBackendTestHelper {

    /// Activate a named scenario and return a fully-configured test environment.
    ///
    /// The returned environment has a real `TPPNetworkExecutor` with the mock
    /// URLProtocol injected, plus a real `OPDSParser`. All app code paths
    /// execute normally — only HTTP responses are mocked.
    ///
    /// Call `deactivate()` in tearDown to clean up.
    static func activate(scenario name: String) throws -> MockBackendEnvironment {
        let scenarioPath = fixturesURL().appendingPathComponent("Scenarios/\(name).json")
        let data = try Data(contentsOf: scenarioPath)
        let scenario = try JSONDecoder().decode(MockScenario.self, from: data)

        // Configure the protocol — set direct path for test fixtures
        MockBackendURLProtocol.activeScenario = scenario
        MockBackendURLProtocol.fixtureDirectoryPath = fixturesURL().path
        MockBackendURLProtocol.fixtureBundle = currentTestBundle()

        // Create executor with mock-injected session
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockBackendURLProtocol.self]

        let session = URLSession(configuration: config)
        let executor = TPPNetworkExecutor(
            cachingStrategy: .ephemeral,
            sessionConfiguration: config
        )

        return MockBackendEnvironment(
            session: session,
            executor: executor,
            parser: OPDSParser(),
            scenario: scenario
        )
    }

    /// Deactivate the mock backend. Call in tearDown.
    static func deactivate() {
        MockBackendURLProtocol.activeScenario = nil
        MockBackendURLProtocol.fixtureDirectoryPath = nil
    }

    // MARK: - Private

    private static func fixturesURL() -> URL {
        // Resolve relative to this source file
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/API")
    }

    private static func currentTestBundle() -> Bundle {
        Bundle(for: MockBackendIntegrationTests.self)
    }
}


