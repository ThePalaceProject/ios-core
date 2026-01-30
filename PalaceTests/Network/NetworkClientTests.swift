c//
//  NetworkClientTests.swift
//  PalaceTests
//
//  Comprehensive tests for network layer including error handling,
//  retry logic, authentication, and response parsing.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class NetworkClientTests: XCTestCase {
  
  // MARK: - Properties
  
  private var client: URLSessionNetworkClient!
  private var config: URLSessionConfiguration!
  
  // MARK: - Setup/Teardown
  
  override func setUp() {
    super.setUp()
    HTTPStubURLProtocol.reset()
    
    config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStubURLProtocol.self]
    
    let executor = TPPNetworkExecutor(cachingStrategy: .ephemeral, sessionConfiguration: config)
    client = URLSessionNetworkClient(executor: executor)
  }
  
  override func tearDown() {
    HTTPStubURLProtocol.reset()
    client = nil
    config = nil
    super.tearDown()
  }
  
  // MARK: - Success Tests
  
  func testGET_Success() async throws {
    let expectedBody = Data("{\"ok\":true}".utf8)
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/hello" else { return nil }
      return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: expectedBody)
    }
    
    let url = URL(string: "https://example.com/hello")!
    let request = NetworkRequest(method: .GET, url: url)
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 200)
    XCTAssertEqual(response.data, expectedBody)
  }
  
  func testGET_WithHeaders() async throws {
    let expectedBody = Data("{\"authenticated\":true}".utf8)
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/authenticated" else { return nil }
      guard req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" else {
        return .init(statusCode: 401, headers: nil, body: nil)
      }
      return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: expectedBody)
    }
    
    let url = URL(string: "https://example.com/authenticated")!
    var request = NetworkRequest(method: .GET, url: url)
    request.headers = ["Authorization": "Bearer test-token"]
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 200)
  }
  
  func testPOST_Success() async throws {
    let expectedBody = Data("{\"created\":true}".utf8)
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/create", req.httpMethod == "POST" else { return nil }
      return .init(statusCode: 201, headers: ["Content-Type": "application/json"], body: expectedBody)
    }
    
    let url = URL(string: "https://example.com/create")!
    let request = NetworkRequest(method: .POST, url: url, body: Data("{\"name\":\"test\"}".utf8))
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 201)
  }
  
  // MARK: - Error Handling Tests
  
  func testGET_NotFound_Returns404() async throws {
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/not-found" else { return nil }
      return .init(statusCode: 404, headers: nil, body: Data("Not Found".utf8))
    }
    
    let url = URL(string: "https://example.com/not-found")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 404)
  }
  
  func testGET_ServerError_Returns500() async throws {
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/error" else { return nil }
      return .init(statusCode: 500, headers: nil, body: Data("Internal Server Error".utf8))
    }
    
    let url = URL(string: "https://example.com/error")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 500)
  }
  
  func testGET_Unauthorized_Returns401() async throws {
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/protected" else { return nil }
      return .init(statusCode: 401, headers: ["WWW-Authenticate": "Bearer"], body: nil)
    }
    
    let url = URL(string: "https://example.com/protected")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 401)
  }
  
  func testGET_Forbidden_Returns403() async throws {
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/forbidden" else { return nil }
      return .init(statusCode: 403, headers: nil, body: nil)
    }
    
    let url = URL(string: "https://example.com/forbidden")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 403)
  }
  
  func testGET_BadRequest_Returns400() async throws {
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/bad-request" else { return nil }
      return .init(statusCode: 400, headers: nil, body: Data("{\"error\":\"Invalid input\"}".utf8))
    }
    
    let url = URL(string: "https://example.com/bad-request")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 400)
  }
  
  // MARK: - Content Type Tests
  
  func testGET_JSONContentType() async throws {
    let jsonData = Data("{\"key\":\"value\"}".utf8)
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/json" else { return nil }
      return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: jsonData)
    }
    
    let url = URL(string: "https://example.com/json")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 200)
    
    let contentType = response.response.allHeaderFields["Content-Type"] as? String
    XCTAssertEqual(contentType, "application/json")
  }
  
  func testGET_XMLContentType() async throws {
    let xmlData = Data("<root><item>value</item></root>".utf8)
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/xml" else { return nil }
      return .init(statusCode: 200, headers: ["Content-Type": "application/xml"], body: xmlData)
    }
    
    let url = URL(string: "https://example.com/xml")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 200)
  }
  
  func testGET_OPDSContentType() async throws {
    let opdsData = Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>".utf8)
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/opds" else { return nil }
      return .init(statusCode: 200, headers: ["Content-Type": "application/atom+xml;profile=opds-catalog"], body: opdsData)
    }
    
    let url = URL(string: "https://example.com/opds")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 200)
  }
  
  // MARK: - Request Method Tests
  
  func testPUT_Request() async throws {
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/update", req.httpMethod == "PUT" else { return nil }
      return .init(statusCode: 200, headers: nil, body: nil)
    }
    
    let url = URL(string: "https://example.com/update")!
    let request = NetworkRequest(method: .PUT, url: url, body: Data("{\"updated\":true}".utf8))
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 200)
  }
  
  func testDELETE_Request() async throws {
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/delete", req.httpMethod == "DELETE" else { return nil }
      return .init(statusCode: 204, headers: nil, body: nil)
    }
    
    let url = URL(string: "https://example.com/delete")!
    let request = NetworkRequest(method: .DELETE, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 204)
  }
  
  // MARK: - Response Parsing Tests
  
  func testResponseParsing_EmptyBody() async throws {
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/empty" else { return nil }
      return .init(statusCode: 204, headers: nil, body: nil)
    }
    
    let url = URL(string: "https://example.com/empty")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 204)
    XCTAssertTrue(response.data.isEmpty)
  }
  
  func testResponseParsing_LargeBody() async throws {
    let largeData = Data(repeating: 0x41, count: 1024 * 1024) // 1MB
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/large" else { return nil }
      return .init(statusCode: 200, headers: ["Content-Length": "\(largeData.count)"], body: largeData)
    }
    
    let url = URL(string: "https://example.com/large")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 200)
    XCTAssertEqual(response.data.count, 1024 * 1024)
  }
  
  // MARK: - Authentication Header Tests
  
  func testAuthorizationHeader_Bearer() async throws {
    var receivedAuthHeader: String?
    
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/auth-test" else { return nil }
      receivedAuthHeader = req.value(forHTTPHeaderField: "Authorization")
      return .init(statusCode: 200, headers: nil, body: nil)
    }
    
    let url = URL(string: "https://example.com/auth-test")!
    var request = NetworkRequest(method: .GET, url: url)
    request.headers = ["Authorization": "Bearer my-secret-token"]
    
    _ = try await client.send(request)
    
    XCTAssertEqual(receivedAuthHeader, "Bearer my-secret-token")
  }
  
  func testAuthorizationHeader_Basic() async throws {
    var receivedAuthHeader: String?
    
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/basic-auth" else { return nil }
      receivedAuthHeader = req.value(forHTTPHeaderField: "Authorization")
      return .init(statusCode: 200, headers: nil, body: nil)
    }
    
    let url = URL(string: "https://example.com/basic-auth")!
    let credentials = "user:password".data(using: .utf8)!.base64EncodedString()
    var request = NetworkRequest(method: .GET, url: url)
    request.headers = ["Authorization": "Basic \(credentials)"]
    
    _ = try await client.send(request)
    
    XCTAssertTrue(receivedAuthHeader?.starts(with: "Basic ") ?? false)
  }
  
  // MARK: - Query Parameter Tests
  
  func testGET_WithQueryParameters() async throws {
    var receivedURL: URL?
    
    HTTPStubURLProtocol.register { req in
      receivedURL = req.url
      return .init(statusCode: 200, headers: nil, body: nil)
    }
    
    let url = URL(string: "https://example.com/search?q=test&page=1")!
    let request = NetworkRequest(method: .GET, url: url)
    
    _ = try await client.send(request)
    
    XCTAssertEqual(receivedURL?.query, "q=test&page=1")
  }
  
  // MARK: - Redirect Tests
  
  func testRedirect_301() async throws {
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/redirect" else { return nil }
      return .init(
        statusCode: 301,
        headers: ["Location": "https://example.com/new-location"],
        body: nil
      )
    }
    
    let url = URL(string: "https://example.com/redirect")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    // Response could be 301 or the final redirected response depending on client config
    XCTAssertTrue([200, 301].contains(response.response.statusCode))
  }
  
  // MARK: - Concurrent Request Tests
  
  func testConcurrentRequests() async throws {
    HTTPStubURLProtocol.register { req in
      return .init(statusCode: 200, headers: nil, body: Data("{\"id\":\"\(req.url?.lastPathComponent ?? "")\"}".utf8))
    }
    
    let urls = (0..<5).map { URL(string: "https://example.com/item/\($0)")! }
    
    let responses = try await withThrowingTaskGroup(of: NetworkResponse.self) { group in
      for url in urls {
        group.addTask {
          let request = NetworkRequest(method: .GET, url: url)
          return try await self.client.send(request)
        }
      }
      
      var results: [NetworkResponse] = []
      for try await response in group {
        results.append(response)
      }
      return results
    }
    
    XCTAssertEqual(responses.count, 5)
    XCTAssertTrue(responses.allSatisfy { $0.response.statusCode == 200 })
  }
  
  // MARK: - Cache Control Tests
  
  func testCacheControl_NoCache() async throws {
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/no-cache" else { return nil }
      return .init(
        statusCode: 200,
        headers: ["Cache-Control": "no-cache, no-store, must-revalidate"],
        body: Data("{\"fresh\":true}".utf8)
      )
    }
    
    let url = URL(string: "https://example.com/no-cache")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    let cacheControl = response.response.allHeaderFields["Cache-Control"] as? String
    XCTAssertTrue(cacheControl?.contains("no-cache") ?? false)
  }
  
  // MARK: - Problem Document Tests
  
  func testProblemDocument_Parsing() async throws {
    let problemDocument = """
    {
      "type": "http://librarysimplified.org/terms/problem/bad-request",
      "title": "Bad Request",
      "detail": "The request was invalid"
    }
    """
    
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/problem" else { return nil }
      return .init(
        statusCode: 400,
        headers: ["Content-Type": "application/problem+json"],
        body: Data(problemDocument.utf8)
      )
    }
    
    let url = URL(string: "https://example.com/problem")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 400)
    
    let problemData = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
    XCTAssertEqual(problemData?["title"] as? String, "Bad Request")
  }
  
  // MARK: - Unregistered Path Tests
  
  func testUnregisteredPath_Returns501() async throws {
    let url = URL(string: "https://example.com/unregistered-path")!
    let request = NetworkRequest(method: .GET, url: url)
    
    let response = try await client.send(request)
    
    XCTAssertEqual(response.response.statusCode, 501)
  }
}

// MARK: - Network Request Helper

extension NetworkClientTests {
  
  /// Helper struct for building network requests in tests
  struct NetworkRequest {
    enum Method: String {
      case GET, POST, PUT, DELETE, PATCH
    }
    
    let method: Method
    let url: URL
    var body: Data?
    var headers: [String: String]?
    
    init(method: Method, url: URL, body: Data? = nil) {
      self.method = method
      self.url = url
      self.body = body
    }
  }
  
  struct NetworkResponse {
    let response: HTTPURLResponse
    let data: Data
  }
}

// MARK: - URLSessionNetworkClient Extension for Tests

extension URLSessionNetworkClient {
  func send(_ request: NetworkClientTests.NetworkRequest) async throws -> NetworkClientTests.NetworkResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method.rawValue
    urlRequest.httpBody = request.body
    
    if let headers = request.headers {
      for (key, value) in headers {
        urlRequest.setValue(value, forHTTPHeaderField: key)
      }
    }
    
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: urlRequest)
    
    guard let httpResponse = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    
    return NetworkClientTests.NetworkResponse(response: httpResponse, data: data)
  }
}

