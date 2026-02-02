//
//  NetworkClientMock.swift
//  PalaceTests
//
//  Mock implementation of NetworkClient for testing network-dependent classes.
//  Allows complete control over network responses without making real HTTP requests.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

/// Mock implementation of NetworkClient for isolated testing of network-dependent code
final class NetworkClientMock: NetworkClient {

  // MARK: - Configuration

  /// Response to return for specific URLs
  var stubbedResponses: [URL: NetworkResponse] = [:]

  /// Default response to return when no specific stub is set
  var defaultResponse: NetworkResponse?

  /// Error to throw (takes precedence over stubbedResponses if set)
  var errorToThrow: Error?

  /// Map of URL patterns to errors for targeted error injection
  var errorsByURL: [URL: Error] = [:]

  /// Delay to simulate network latency (in seconds)
  var simulatedDelay: TimeInterval = 0

  /// Whether to simulate a slow connection
  var simulateSlowConnection: Bool = false

  /// Fail after a certain number of calls (for testing retry logic)
  var failAfterCallCount: Int?

  /// Status code to return for default responses
  var defaultStatusCode: Int = 200

  // MARK: - Call Tracking

  /// Number of times send was called
  private(set) var sendCallCount = 0

  /// The last request that was sent
  private(set) var lastRequest: NetworkRequest?

  /// All requests that were sent (for verifying request history)
  private(set) var requestHistory: [NetworkRequest] = []

  /// The last URL that was requested
  var lastRequestedURL: URL? {
    lastRequest?.url
  }

  /// The last HTTP method that was used
  var lastRequestedMethod: HTTPMethod? {
    lastRequest?.method
  }

  /// The last headers that were sent
  var lastRequestedHeaders: [String: String]? {
    lastRequest?.headers
  }

  /// The last body that was sent
  var lastRequestedBody: Data? {
    lastRequest?.body
  }

  // MARK: - NetworkClient Implementation

  func send(_ request: NetworkRequest) async throws -> NetworkResponse {
    sendCallCount += 1
    lastRequest = request
    requestHistory.append(request)

    // Check if we should fail after N calls
    if let failAfter = failAfterCallCount, sendCallCount > failAfter {
      throw NetworkClientMockError.simulatedFailure(
        "Simulated failure after \(failAfter) calls"
      )
    }

    // Simulate network delay
    if simulatedDelay > 0 || simulateSlowConnection {
      let delay = simulateSlowConnection ? 2.0 : simulatedDelay
      try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    // Check for global error
    if let error = errorToThrow {
      throw error
    }

    // Check for URL-specific error
    if let urlError = errorsByURL[request.url] {
      throw urlError
    }

    // Return stubbed response for URL
    if let stubbedResponse = stubbedResponses[request.url] {
      return stubbedResponse
    }

    // Return default response
    if let defaultResponse = defaultResponse {
      return defaultResponse
    }

    // Create a default empty response if nothing else is configured
    return makeDefaultResponse(for: request.url)
  }

  // MARK: - Test Helpers

  /// Resets all tracking state and configuration
  func reset() {
    stubbedResponses = [:]
    defaultResponse = nil
    errorToThrow = nil
    errorsByURL = [:]
    simulatedDelay = 0
    simulateSlowConnection = false
    failAfterCallCount = nil
    defaultStatusCode = 200
    sendCallCount = 0
    lastRequest = nil
    requestHistory = []
  }

  /// Check if a specific URL was requested
  func wasURLRequested(_ url: URL) -> Bool {
    requestHistory.contains { $0.url == url }
  }

  /// Check if a specific HTTP method was used for a URL
  func wasMethodUsed(_ method: HTTPMethod, forURL url: URL) -> Bool {
    requestHistory.contains { $0.url == url && $0.method == method }
  }

  /// Get all requests made to a specific URL
  func requests(forURL url: URL) -> [NetworkRequest] {
    requestHistory.filter { $0.url == url }
  }

  /// Stub a successful JSON response for a URL
  func stubJSONResponse(for url: URL, json: String, statusCode: Int = 200) {
    let data = Data(json.utf8)
    let httpResponse = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    stubbedResponses[url] = NetworkResponse(data: data, response: httpResponse)
  }

  /// Stub a successful XML/OPDS response for a URL
  func stubOPDSResponse(for url: URL, xml: String, statusCode: Int = 200) {
    let data = Data(xml.utf8)
    let httpResponse = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/atom+xml;profile=opds-catalog"]
    )!
    stubbedResponses[url] = NetworkResponse(data: data, response: httpResponse)
  }

  /// Stub an error response for a URL
  func stubErrorResponse(for url: URL, statusCode: Int, message: String = "") {
    let data = Data(message.utf8)
    let httpResponse = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    stubbedResponses[url] = NetworkResponse(data: data, response: httpResponse)
  }

  /// Create a default response for a URL
  private func makeDefaultResponse(for url: URL) -> NetworkResponse {
    let httpResponse = HTTPURLResponse(
      url: url,
      statusCode: defaultStatusCode,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return NetworkResponse(data: Data(), response: httpResponse)
  }
}

// MARK: - Mock Errors

enum NetworkClientMockError: Error, LocalizedError {
  case simulatedFailure(String)
  case networkUnavailable
  case timeout
  case unauthorized
  case serverError(Int)
  case invalidResponse
  case parsingError

  var errorDescription: String? {
    switch self {
    case .simulatedFailure(let message):
      return message
    case .networkUnavailable:
      return "Network is unavailable"
    case .timeout:
      return "Request timed out"
    case .unauthorized:
      return "Authentication required"
    case .serverError(let code):
      return "Server returned error \(code)"
    case .invalidResponse:
      return "Invalid response received"
    case .parsingError:
      return "Failed to parse response"
    }
  }
}

// MARK: - Test Data Factory

extension NetworkClientMock {

  /// Create a minimal valid OPDS feed XML
  static func makeOPDSFeedXML(title: String = "Test Feed", entries: Int = 0) -> String {
    var entriesXML = ""
    for i in 0..<entries {
      entriesXML += """
        <entry>
          <id>urn:uuid:entry-\(i)</id>
          <title>Entry \(i)</title>
          <updated>2024-01-01T00:00:00Z</updated>
        </entry>
      """
    }

    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
      <id>urn:uuid:test-feed</id>
      <title>\(title)</title>
      <updated>2024-01-01T00:00:00Z</updated>
      \(entriesXML)
    </feed>
    """
  }

  /// Create a problem document JSON
  static func makeProblemDocumentJSON(
    type: String = "http://librarysimplified.org/terms/problem/bad-request",
    title: String = "Bad Request",
    detail: String = "The request was invalid"
  ) -> String {
    return """
    {
      "type": "\(type)",
      "title": "\(title)",
      "detail": "\(detail)"
    }
    """
  }
}
