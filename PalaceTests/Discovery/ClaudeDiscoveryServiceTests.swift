import XCTest
@testable import Palace

final class ClaudeDiscoveryServiceTests: XCTestCase {
    private var service: ClaudeDiscoveryService!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
        session = .stubbedSession()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        service = nil
        session = nil
        super.tearDown()
    }

    // MARK: - Fallback When No API Key

    func testFallsBackWhenNoAPIKey() async throws {
        let config = TestDiscoveryConfiguration(apiKey: nil)
        service = ClaudeDiscoveryService(
            configuration: config,
            session: session,
            fallback: LocalDiscoveryFallback()
        )

        let prompt = DiscoveryPrompt(mood: .relaxing)
        let results = try await service.getRecommendations(prompt: prompt)

        // Should get fallback results (local recommendations based on mood)
        XCTAssertFalse(results.isEmpty)
        XCTAssertFalse(service.isAvailable)
    }

    // MARK: - Successful API Response

    func testSuccessfulAPIResponse() async throws {
        let config = TestDiscoveryConfiguration(apiKey: "test-key")
        service = ClaudeDiscoveryService(
            configuration: config,
            session: session,
            fallback: LocalDiscoveryFallback()
        )

        let jsonResponse = """
        {
            "content": [
                {
                    "type": "text",
                    "text": "[{\\"id\\": \\"rec-1\\", \\"title\\": \\"The Night Circus\\", \\"authors\\": [\\"Erin Morgenstern\\"], \\"summary\\": \\"A magical competition\\", \\"reason\\": \\"Perfect for relaxing reading\\", \\"confidence\\": 0.92, \\"categories\\": [\\"Fantasy\\", \\"Romance\\"]}]"
                }
            ]
        }
        """

        HTTPStubURLProtocol.register { request in
            guard request.url?.host == "api.anthropic.com" else { return nil }
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: jsonResponse.data(using: .utf8)
            )
        }

        let prompt = DiscoveryPrompt(freeText: "magical stories")
        let results = try await service.getRecommendations(prompt: prompt)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "The Night Circus")
        XCTAssertEqual(results[0].authors, ["Erin Morgenstern"])
        XCTAssertEqual(results[0].confidenceScore, 0.92)
        XCTAssertEqual(results[0].categories, ["Fantasy", "Romance"])
        XCTAssertTrue(results[0].availability.isEmpty) // Not yet enriched
    }

    // MARK: - API Errors

    func testRateLimitFallsBackToLocal() async throws {
        let config = TestDiscoveryConfiguration(apiKey: "test-key")
        service = ClaudeDiscoveryService(
            configuration: config,
            session: session,
            fallback: LocalDiscoveryFallback()
        )

        HTTPStubURLProtocol.register { request in
            guard request.url?.host == "api.anthropic.com" else { return nil }
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 429,
                headers: ["retry-after": "30"],
                body: nil
            )
        }

        let prompt = DiscoveryPrompt(mood: .thrilling)
        let results = try await service.getRecommendations(prompt: prompt)

        // Should fall back to local recommendations
        XCTAssertFalse(results.isEmpty)
    }

    func testServerErrorFallsBackToLocal() async throws {
        let config = TestDiscoveryConfiguration(apiKey: "test-key")
        service = ClaudeDiscoveryService(
            configuration: config,
            session: session,
            fallback: LocalDiscoveryFallback()
        )

        HTTPStubURLProtocol.register { request in
            guard request.url?.host == "api.anthropic.com" else { return nil }
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 500,
                headers: nil,
                body: "Internal Server Error".data(using: .utf8)
            )
        }

        let prompt = DiscoveryPrompt(freeText: "science fiction")
        let results = try await service.getRecommendations(prompt: prompt)

        // Should fall back to local recommendations
        XCTAssertFalse(results.isEmpty)
    }

    // MARK: - JSON Parsing

    func testParsesResponseWithCodeFences() async throws {
        let config = TestDiscoveryConfiguration(apiKey: "test-key")
        service = ClaudeDiscoveryService(
            configuration: config,
            session: session,
            fallback: LocalDiscoveryFallback()
        )

        // Response wrapped in markdown code fences
        let jsonResponse = """
        {
            "content": [
                {
                    "type": "text",
                    "text": "```json\\n[{\\"id\\": \\"rec-1\\", \\"title\\": \\"Dune\\", \\"authors\\": [\\"Frank Herbert\\"], \\"summary\\": \\"Epic science fiction\\", \\"reason\\": \\"A classic\\", \\"confidence\\": 0.95, \\"categories\\": [\\"Science Fiction\\"]}]\\n```"
                }
            ]
        }
        """

        HTTPStubURLProtocol.register { request in
            guard request.url?.host == "api.anthropic.com" else { return nil }
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: jsonResponse.data(using: .utf8)
            )
        }

        let prompt = DiscoveryPrompt(freeText: "epic sci-fi")
        let results = try await service.getRecommendations(prompt: prompt)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Dune")
    }

    // MARK: - Confidence Score Clamping

    func testConfidenceScoreIsClamped() async throws {
        let config = TestDiscoveryConfiguration(apiKey: "test-key")
        service = ClaudeDiscoveryService(
            configuration: config,
            session: session,
            fallback: LocalDiscoveryFallback()
        )

        let jsonResponse = """
        {
            "content": [
                {
                    "type": "text",
                    "text": "[{\\"id\\": \\"rec-1\\", \\"title\\": \\"Test\\", \\"authors\\": [], \\"summary\\": null, \\"reason\\": \\"test\\", \\"confidence\\": 1.5, \\"categories\\": []}]"
                }
            ]
        }
        """

        HTTPStubURLProtocol.register { request in
            guard request.url?.host == "api.anthropic.com" else { return nil }
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: jsonResponse.data(using: .utf8)
            )
        }

        let prompt = DiscoveryPrompt(freeText: "test")
        let results = try await service.getRecommendations(prompt: prompt)

        XCTAssertEqual(results[0].confidenceScore, 1.0, "Score above 1.0 should be clamped")
    }

    // MARK: - Request Headers

    func testRequestContainsCorrectHeaders() async throws {
        let config = TestDiscoveryConfiguration(apiKey: "sk-test-12345")
        service = ClaudeDiscoveryService(
            configuration: config,
            session: session,
            fallback: LocalDiscoveryFallback()
        )

        var capturedRequest: URLRequest?
        HTTPStubURLProtocol.register { request in
            capturedRequest = request
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: """
                {"content": [{"type": "text", "text": "[]"}]}
                """.data(using: .utf8)
            )
        }

        let prompt = DiscoveryPrompt(freeText: "test")
        _ = try await service.getRecommendations(prompt: prompt)

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-test-12345")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
    }

    // MARK: - Prompt Building

    func testPromptIncludesMoodDescription() async throws {
        let config = TestDiscoveryConfiguration(apiKey: "test-key")
        service = ClaudeDiscoveryService(
            configuration: config,
            session: session,
            fallback: LocalDiscoveryFallback()
        )

        var capturedBody: Data?
        HTTPStubURLProtocol.register { request in
            capturedBody = request.httpBody
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: """
                {"content": [{"type": "text", "text": "[]"}]}
                """.data(using: .utf8)
            )
        }

        let prompt = DiscoveryPrompt(mood: .thrilling)
        _ = try await service.getRecommendations(prompt: prompt)

        if let body = capturedBody, let bodyString = String(data: body, encoding: .utf8) {
            XCTAssertTrue(bodyString.contains("suspenseful"), "Body should contain mood descriptor: \(bodyString)")
        } else {
            XCTFail("Request body should not be nil")
        }
    }
}

// MARK: - Test Configuration

/// A test-friendly DiscoveryConfiguration that allows injecting values.
private struct TestDiscoveryConfiguration: DiscoveryConfiguration {
    let apiKey: String?
    var endpoint: URL { URL(string: "https://api.anthropic.com/v1/messages")! }
    var model: String { "claude-sonnet-4-20250514" }
    var isEnabled: Bool { true }
    var isAIAvailable: Bool { apiKey != nil && isEnabled }
    var maxRecommendations: Int { 20 }
    var requestTimeout: TimeInterval { 10 }

    init(apiKey: String?) {
        self.apiKey = apiKey
    }
}
