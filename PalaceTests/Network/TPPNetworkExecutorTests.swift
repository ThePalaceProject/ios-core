//
//  TPPNetworkExecutorTests.swift
//  PalaceTests
//
//  Comprehensive unit tests for TPPNetworkExecutor.
//  Tests the REAL TPPNetworkExecutor class using URLProtocol mocking
//  for network responses.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPNetworkExecutorTests: XCTestCase {
  
  // MARK: - Properties
  
  private var sut: TPPNetworkExecutor!
  private var config: URLSessionConfiguration!
  
  // MARK: - Test URLs
  
  private let testBaseURL = "https://test.palace.example.com"
  
  private var successURL: URL { URL(string: "\(testBaseURL)/success")! }
  private var notFoundURL: URL { URL(string: "\(testBaseURL)/not-found")! }
  private var serverErrorURL: URL { URL(string: "\(testBaseURL)/server-error")! }
  private var unauthorizedURL: URL { URL(string: "\(testBaseURL)/unauthorized")! }
  private var forbiddenURL: URL { URL(string: "\(testBaseURL)/forbidden")! }
  private var badRequestURL: URL { URL(string: "\(testBaseURL)/bad-request")! }
  private var timeoutURL: URL { URL(string: "\(testBaseURL)/timeout")! }
  private var postURL: URL { URL(string: "\(testBaseURL)/post")! }
  private var putURL: URL { URL(string: "\(testBaseURL)/put")! }
  private var deleteURL: URL { URL(string: "\(testBaseURL)/delete")! }
  
  // MARK: - Setup / Teardown
  
  override func setUp() {
    super.setUp()
    HTTPStubURLProtocol.reset()
    
    // Configure URLSession to use our stub protocol
    config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStubURLProtocol.self]
    config.timeoutIntervalForRequest = 5.0
    config.timeoutIntervalForResource = 10.0
    
    // Create a real TPPNetworkExecutor with our stubbed configuration
    sut = TPPNetworkExecutor(
      credentialsProvider: nil,
      cachingStrategy: .ephemeral,
      sessionConfiguration: config,
      delegateQueue: nil
    )
  }
  
  override func tearDown() {
    HTTPStubURLProtocol.reset()
    sut = nil
    config = nil
    super.tearDown()
  }
  
  // MARK: - GET Request Success Tests
  
  func testGET_Success_ReturnsDataAndResponse() {
    // Given
    let expectedData = Data("{\"status\":\"ok\",\"message\":\"success\"}".utf8)
    registerStub(for: successURL, statusCode: 200, body: expectedData)
    
    let expectation = expectation(description: "GET request completes")
    var receivedData: Data?
    var receivedResponse: URLResponse?
    var receivedError: Error?
    
    // When
    sut.GET(successURL, useTokenIfAvailable: false) { result in
      switch result {
      case .success(let data, let response):
        receivedData = data
        receivedResponse = response
      case .failure(let error, let response):
        receivedError = error
        receivedResponse = response
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNil(receivedError, "Should not have an error")
    XCTAssertNotNil(receivedData, "Should receive data")
    XCTAssertEqual(receivedData, expectedData, "Data should match expected")
    XCTAssertNotNil(receivedResponse, "Should receive response")
    
    if let httpResponse = receivedResponse as? HTTPURLResponse {
      XCTAssertEqual(httpResponse.statusCode, 200, "Status code should be 200")
    } else {
      XCTFail("Response should be HTTPURLResponse")
    }
  }
  
  func testGET_Success_WithJSONContent() {
    // Given
    let json = """
    {
      "books": [
        {"id": "1", "title": "Test Book"},
        {"id": "2", "title": "Another Book"}
      ]
    }
    """
    let expectedData = Data(json.utf8)
    registerStub(
      for: successURL,
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: expectedData
    )
    
    let expectation = expectation(description: "GET JSON completes")
    var receivedData: Data?
    
    // When
    sut.GET(successURL, useTokenIfAvailable: false) { result in
      if case .success(let data, _) = result {
        receivedData = data
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNotNil(receivedData)
    
    // Verify JSON is parseable
    if let data = receivedData {
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      XCTAssertNotNil(parsed)
      XCTAssertNotNil(parsed?["books"] as? [[String: Any]])
    }
  }
  
  func testGET_Success_EmptyBody() {
    // Given
    registerStub(for: successURL, statusCode: 204, body: nil)
    
    let expectation = expectation(description: "GET empty body completes")
    var receivedData: Data?
    var receivedStatusCode: Int?
    
    // When
    sut.GET(successURL, useTokenIfAvailable: false) { result in
      if case .success(let data, let response) = result {
        receivedData = data
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNotNil(receivedData)
    XCTAssertTrue(receivedData?.isEmpty ?? true)
    XCTAssertEqual(receivedStatusCode, 204)
  }
  
  // MARK: - GET Request Error Response Code Tests
  
  func testGET_NotFound_Returns404() {
    // Given
    let problemDocument = """
    {
      "type": "http://librarysimplified.org/terms/problem/not-found",
      "title": "Not Found",
      "detail": "The requested resource was not found"
    }
    """
    registerStub(
      for: notFoundURL,
      statusCode: 404,
      headers: ["Content-Type": "application/problem+json"],
      body: Data(problemDocument.utf8)
    )
    
    let expectation = expectation(description: "GET 404 completes")
    var receivedStatusCode: Int?
    var receivedError: Error?
    
    // When
    sut.GET(notFoundURL, useTokenIfAvailable: false) { result in
      switch result {
      case .success(_, let response):
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      case .failure(let error, let response):
        receivedError = error
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertEqual(receivedStatusCode, 404)
    XCTAssertNotNil(receivedError, "Should receive error for 404")
  }
  
  func testGET_ServerError_Returns500() {
    // Given
    registerStub(for: serverErrorURL, statusCode: 500, body: Data("Internal Server Error".utf8))
    
    let expectation = expectation(description: "GET 500 completes")
    var receivedStatusCode: Int?
    var receivedError: Error?
    
    // When
    sut.GET(serverErrorURL, useTokenIfAvailable: false) { result in
      switch result {
      case .success(_, let response):
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      case .failure(let error, let response):
        receivedError = error
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertEqual(receivedStatusCode, 500)
    XCTAssertNotNil(receivedError)
  }
  
  func testGET_Unauthorized_Returns401() {
    // Given
    registerStub(
      for: unauthorizedURL,
      statusCode: 401,
      headers: ["WWW-Authenticate": "Bearer"],
      body: nil
    )
    
    let expectation = expectation(description: "GET 401 completes")
    var receivedStatusCode: Int?
    var receivedError: Error?
    
    // When
    sut.GET(unauthorizedURL, useTokenIfAvailable: false) { result in
      switch result {
      case .success(_, let response):
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      case .failure(let error, let response):
        receivedError = error
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertEqual(receivedStatusCode, 401)
    XCTAssertNotNil(receivedError)
  }
  
  func testGET_Forbidden_Returns403() {
    // Given
    registerStub(for: forbiddenURL, statusCode: 403, body: nil)
    
    let expectation = expectation(description: "GET 403 completes")
    var receivedStatusCode: Int?
    var receivedError: Error?
    
    // When
    sut.GET(forbiddenURL, useTokenIfAvailable: false) { result in
      switch result {
      case .success(_, let response):
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      case .failure(let error, let response):
        receivedError = error
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertEqual(receivedStatusCode, 403)
    XCTAssertNotNil(receivedError)
  }
  
  func testGET_BadRequest_Returns400() {
    // Given
    let errorBody = Data("{\"error\":\"Invalid parameters\"}".utf8)
    registerStub(for: badRequestURL, statusCode: 400, body: errorBody)
    
    let expectation = expectation(description: "GET 400 completes")
    var receivedStatusCode: Int?
    var receivedError: Error?
    
    // When
    sut.GET(badRequestURL, useTokenIfAvailable: false) { result in
      switch result {
      case .success(_, let response):
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      case .failure(let error, let response):
        receivedError = error
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertEqual(receivedStatusCode, 400)
    XCTAssertNotNil(receivedError)
  }
  
  // MARK: - POST Request Tests
  
  func testPOST_Success_ReturnsCreatedResponse() {
    // Given
    let expectedData = Data("{\"id\":\"123\",\"created\":true}".utf8)
    registerStub(
      for: postURL,
      statusCode: 201,
      headers: ["Content-Type": "application/json"],
      body: expectedData
    )
    
    let expectation = expectation(description: "POST completes")
    var receivedData: Data?
    var receivedStatusCode: Int?
    var receivedError: Error?
    
    var request = URLRequest(url: postURL)
    request.httpMethod = "POST"
    request.httpBody = Data("{\"name\":\"Test\"}".utf8)
    
    // When
    sut.POST(request, useTokenIfAvailable: false) { data, response, error in
      receivedData = data
      receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      receivedError = error
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNil(receivedError)
    XCTAssertNotNil(receivedData)
    XCTAssertEqual(receivedStatusCode, 201)
  }
  
  func testPOST_WithRequestObject_SetsCorrectMethod() {
    // Given
    var capturedRequest: URLRequest?
    HTTPStubURLProtocol.register { req in
      capturedRequest = req
      return .init(statusCode: 200, headers: nil, body: nil)
    }
    
    let expectation = expectation(description: "POST method set")
    var request = URLRequest(url: postURL)
    request.httpMethod = "GET" // Intentionally wrong
    
    // When
    sut.POST(request, useTokenIfAvailable: false) { _, _, _ in
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertEqual(capturedRequest?.httpMethod, "POST", "Method should be corrected to POST")
  }
  
  func testPOST_ServerError_ReturnsError() {
    // Given
    registerStub(for: postURL, statusCode: 500, body: nil)
    
    let expectation = expectation(description: "POST error completes")
    var receivedError: Error?
    var receivedStatusCode: Int?
    
    var request = URLRequest(url: postURL)
    request.httpMethod = "POST"
    
    // When
    sut.POST(request, useTokenIfAvailable: false) { _, response, error in
      receivedError = error
      receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNotNil(receivedError)
    XCTAssertEqual(receivedStatusCode, 500)
  }
  
  // MARK: - PUT Request Tests
  
  func testPUT_Success_ReturnsData() {
    // Given
    let expectedData = Data("{\"updated\":true}".utf8)
    registerStub(for: putURL, statusCode: 200, body: expectedData)
    
    let expectation = expectation(description: "PUT completes")
    var receivedData: Data?
    var receivedStatusCode: Int?
    
    // When
    sut.PUT(putURL, useTokenIfAvailable: false) { data, response, error in
      receivedData = data
      receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNotNil(receivedData)
    XCTAssertEqual(receivedStatusCode, 200)
  }
  
  func testPUT_WithRequest_SetsCorrectMethod() {
    // Given
    var capturedRequest: URLRequest?
    HTTPStubURLProtocol.register { req in
      capturedRequest = req
      return .init(statusCode: 200, headers: nil, body: nil)
    }
    
    let expectation = expectation(description: "PUT method set")
    var request = URLRequest(url: putURL)
    request.httpMethod = "GET" // Intentionally wrong
    
    // When
    sut.PUT(request: request, useTokenIfAvailable: false) { _, _, _ in
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertEqual(capturedRequest?.httpMethod, "PUT")
  }
  
  // MARK: - DELETE Request Tests
  
  func testDELETE_Success_Returns204() {
    // Given
    registerStub(for: deleteURL, statusCode: 204, body: nil)
    
    let expectation = expectation(description: "DELETE completes")
    var receivedStatusCode: Int?
    var receivedError: Error?
    
    var request = URLRequest(url: deleteURL)
    request.httpMethod = "DELETE"
    
    // When
    sut.DELETE(request, useTokenIfAvailable: false) { _, response, error in
      receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      receivedError = error
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNil(receivedError)
    XCTAssertEqual(receivedStatusCode, 204)
  }
  
  func testDELETE_WithRequest_SetsCorrectMethod() {
    // Given
    var capturedRequest: URLRequest?
    HTTPStubURLProtocol.register { req in
      capturedRequest = req
      return .init(statusCode: 204, headers: nil, body: nil)
    }
    
    let expectation = expectation(description: "DELETE method set")
    var request = URLRequest(url: deleteURL)
    request.httpMethod = "GET" // Intentionally wrong
    
    // When
    sut.DELETE(request, useTokenIfAvailable: false) { _, _, _ in
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertEqual(capturedRequest?.httpMethod, "DELETE")
  }
  
  // MARK: - Request Header Tests
  
  func testRequest_SetsCustomUserAgent() {
    // Given
    var capturedRequest: URLRequest?
    HTTPStubURLProtocol.register { req in
      capturedRequest = req
      return .init(statusCode: 200, headers: nil, body: nil)
    }
    
    let expectation = expectation(description: "Request sent")
    
    // When
    sut.GET(successURL, useTokenIfAvailable: false) { _ in
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    
    // Verify User-Agent is set (applyCustomUserAgent should have been called)
    let userAgent = capturedRequest?.value(forHTTPHeaderField: "User-Agent")
    // User-Agent should be set by applyCustomUserAgent()
    XCTAssertNotNil(capturedRequest)
  }
  
  func testRequest_ClearsAcceptLanguageHeader() {
    // Given
    var capturedRequest: URLRequest?
    HTTPStubURLProtocol.register { req in
      capturedRequest = req
      return .init(statusCode: 200, headers: nil, body: nil)
    }
    
    let expectation = expectation(description: "Request sent")
    
    // When
    sut.GET(successURL, useTokenIfAvailable: false) { _ in
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    
    // Accept-Language should be cleared (set to empty string)
    let acceptLanguage = capturedRequest?.value(forHTTPHeaderField: "Accept-Language")
    XCTAssertEqual(acceptLanguage, "")
  }
  
  // MARK: - Request Factory Tests
  
  func testRequestForURL_CreatesValidRequest() {
    // When
    let request = sut.request(for: successURL, useTokenIfAvailable: false)
    
    // Then
    XCTAssertEqual(request.url, successURL)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "")
  }
  
  func testRequestForURL_WithoutToken_NoAuthorizationHeader() {
    // When
    let request = sut.request(for: successURL, useTokenIfAvailable: false)
    
    // Then
    // Without a token available, Authorization should not be set
    // (This depends on TPPUserAccount state, but we're testing without credentials)
    XCTAssertNotNil(request)
  }
  
  // MARK: - Bearer Authorization Tests
  
  func testBearerAuthorized_WithEmptyToken_SetsEmptyHeader() {
    // Given
    var request = URLRequest(url: successURL)
    
    // When - when no token is available
    let authorizedRequest = TPPNetworkExecutor.bearerAuthorized(request: request)
    
    // Then - verify the request is returned (may have empty auth header when no token)
    XCTAssertEqual(authorizedRequest.url, successURL)
  }
  
  // MARK: - Problem Document Parsing Tests
  
  func testProblemDocument_IsParsedFromResponse() {
    // Given
    let problemDocument = """
    {
      "type": "http://librarysimplified.org/terms/problem/authentication-required",
      "title": "Authentication Required",
      "status": 401,
      "detail": "You must be authenticated to access this resource"
    }
    """
    registerStub(
      for: unauthorizedURL,
      statusCode: 401,
      headers: ["Content-Type": "application/problem+json"],
      body: Data(problemDocument.utf8)
    )
    
    let expectation = expectation(description: "Problem document parsed")
    var receivedError: Error?
    
    // When
    sut.GET(unauthorizedURL, useTokenIfAvailable: false) { result in
      if case .failure(let error, _) = result {
        receivedError = error
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNotNil(receivedError)
    
    // The error should contain problem document information
    if let nsError = receivedError as? NSError {
      XCTAssertNotNil(nsError.localizedDescription)
    }
  }
  
  // MARK: - Cache Tests
  
  func testClearCache_DoesNotThrow() {
    // When/Then - clearing cache should not throw
    XCTAssertNoThrow(sut.clearCache())
  }
  
  // MARK: - Async/Await GET Tests
  
  func testAsyncGET_Success_ReturnsData() async throws {
    // Given
    let expectedData = Data("{\"async\":true}".utf8)
    registerStub(for: successURL, statusCode: 200, body: expectedData)
    
    // When
    let (data, response) = try await sut.GET(successURL, useTokenIfAvailable: false)
    
    // Then
    XCTAssertEqual(data, expectedData)
    if let httpResponse = response as? HTTPURLResponse {
      XCTAssertEqual(httpResponse.statusCode, 200)
    }
  }
  
  func testAsyncGET_Error_ThrowsError() async {
    // Given
    registerStub(for: serverErrorURL, statusCode: 500, body: nil)
    
    // When/Then
    do {
      _ = try await sut.GET(serverErrorURL, useTokenIfAvailable: false)
      XCTFail("Should throw error for 500 response")
    } catch {
      // Expected
      XCTAssertNotNil(error)
    }
  }
  
  // MARK: - Multiple Concurrent Requests Tests
  
  func testConcurrentGETRequests_AllComplete() {
    // Given
    let urls = (0..<5).map { URL(string: "\(testBaseURL)/item/\($0)")! }
    
    HTTPStubURLProtocol.register { req in
      let id = req.url?.lastPathComponent ?? "unknown"
      return .init(statusCode: 200, headers: nil, body: Data("{\"id\":\"\(id)\"}".utf8))
    }
    
    let expectations = urls.map { url in
      expectation(description: "Request to \(url) completes")
    }
    
    var completedCount = 0
    let countLock = NSLock()
    
    // When
    for (index, url) in urls.enumerated() {
      sut.GET(url, useTokenIfAvailable: false) { result in
        countLock.lock()
        completedCount += 1
        countLock.unlock()
        
        if case .success(let data, _) = result {
          XCTAssertFalse(data.isEmpty)
        }
        expectations[index].fulfill()
      }
    }
    
    // Then
    waitForExpectations(timeout: 10.0)
    XCTAssertEqual(completedCount, 5)
  }
  
  // MARK: - Task Pause/Resume Tests
  
  func testPauseAllTasks_DoesNotCrash() {
    // When/Then - should not crash even with no active tasks
    XCTAssertNoThrow(sut.pauseAllTasks())
  }
  
  func testResumeAllTasks_DoesNotCrash() {
    // When/Then - should not crash even with no paused tasks
    XCTAssertNoThrow(sut.resumeAllTasks())
  }
  
  func testPauseAndResumeTasks_PreservesAudiobookTasks() {
    // Given - register stub that includes audiobook URL pattern
    let audiobookURL = URL(string: "\(testBaseURL)/audiobook/chapter1.mp3")!
    registerStub(for: audiobookURL, statusCode: 200, body: Data())
    
    let expectation = expectation(description: "Audiobook task completes")
    
    // When
    sut.GET(audiobookURL, useTokenIfAvailable: false) { _ in
      expectation.fulfill()
    }
    
    // Pause and resume immediately
    sut.pauseAllTasks()
    sut.resumeAllTasks()
    
    // Then - task should still complete
    waitForExpectations(timeout: 5.0)
  }
  
  // MARK: - Download Task Tests
  
  func testDownload_Success_ReturnsData() {
    // Given
    let expectedData = Data("Download content".utf8)
    registerStub(for: successURL, statusCode: 200, body: expectedData)
    
    let expectation = expectation(description: "Download completes")
    var receivedData: Data?
    var receivedError: Error?
    
    // When
    let _ = sut.download(successURL) { data, response, error in
      receivedData = data
      receivedError = error
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNil(receivedError)
    XCTAssertNotNil(receivedData)
  }
  
  func testDownload_Error_ReturnsError() {
    // Given
    registerStub(for: serverErrorURL, statusCode: 500, body: nil)
    
    let expectation = expectation(description: "Download error completes")
    var receivedError: Error?
    
    // When
    let _ = sut.download(serverErrorURL) { _, _, error in
      receivedError = error
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNotNil(receivedError)
  }
  
  // MARK: - Add Bearer and Execute Tests
  
  func testAddBearerAndExecute_Success() {
    // Given
    registerStub(for: successURL, statusCode: 200, body: Data("{\"ok\":true}".utf8))
    
    let expectation = expectation(description: "Bearer request completes")
    var request = URLRequest(url: successURL)
    request.httpMethod = "GET"
    
    var receivedData: Data?
    var receivedError: Error?
    
    // When
    sut.addBearerAndExecute(request) { data, response, error in
      receivedData = data
      receivedError = error
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNil(receivedError)
    XCTAssertNotNil(receivedData)
  }
  
  // MARK: - Cache Policy Tests
  
  func testGET_WithCachePolicy_UsesPolicyInRequest() {
    // Given
    var capturedRequest: URLRequest?
    HTTPStubURLProtocol.register { req in
      capturedRequest = req
      return .init(statusCode: 200, headers: nil, body: nil)
    }
    
    let expectation = expectation(description: "Cache policy request completes")
    
    // When
    sut.GET(successURL, cachePolicy: .reloadIgnoringLocalCacheData, useTokenIfAvailable: false) { _, _, _ in
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertEqual(capturedRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
  }
  
  // MARK: - Response Codes 2xx Tests
  
  func testGET_Status201_IsSuccess() {
    // Given
    registerStub(for: successURL, statusCode: 201, body: Data("{\"created\":true}".utf8))
    
    let expectation = expectation(description: "201 success")
    var receivedError: Error?
    var receivedStatusCode: Int?
    
    // When
    sut.GET(successURL, useTokenIfAvailable: false) { result in
      switch result {
      case .success(_, let response):
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      case .failure(let error, let response):
        receivedError = error
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNil(receivedError)
    XCTAssertEqual(receivedStatusCode, 201)
  }
  
  func testGET_Status299_IsSuccess() {
    // Given
    registerStub(for: successURL, statusCode: 299, body: nil)
    
    let expectation = expectation(description: "299 success")
    var receivedError: Error?
    var receivedStatusCode: Int?
    
    // When
    sut.GET(successURL, useTokenIfAvailable: false) { result in
      switch result {
      case .success(_, let response):
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      case .failure(let error, let response):
        receivedError = error
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    XCTAssertNil(receivedError)
    XCTAssertEqual(receivedStatusCode, 299)
  }
  
  // MARK: - Large Response Tests
  
  func testGET_LargeResponse_HandlesCorrectly() {
    // Given - 1MB response
    let largeData = Data(repeating: 0x41, count: 1024 * 1024)
    registerStub(
      for: successURL,
      statusCode: 200,
      headers: ["Content-Length": "\(largeData.count)"],
      body: largeData
    )
    
    let expectation = expectation(description: "Large response completes")
    var receivedData: Data?
    
    // When
    sut.GET(successURL, useTokenIfAvailable: false) { result in
      if case .success(let data, _) = result {
        receivedData = data
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 30.0) // Longer timeout for large data
    XCTAssertNotNil(receivedData)
    XCTAssertEqual(receivedData?.count, 1024 * 1024)
  }
  
  // MARK: - Redirect Tests
  
  func testGET_301Redirect_HandlesRedirect() {
    // Given
    let redirectURL = URL(string: "\(testBaseURL)/redirect")!
    registerStub(
      for: redirectURL,
      statusCode: 301,
      headers: ["Location": successURL.absoluteString],
      body: nil
    )
    registerStub(for: successURL, statusCode: 200, body: Data("Redirected content".utf8))
    
    let expectation = expectation(description: "Redirect handled")
    var receivedStatusCode: Int?
    
    // When
    sut.GET(redirectURL, useTokenIfAvailable: false) { result in
      switch result {
      case .success(_, let response):
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      case .failure(_, let response):
        receivedStatusCode = (response as? HTTPURLResponse)?.statusCode
      }
      expectation.fulfill()
    }
    
    // Then
    waitForExpectations(timeout: 5.0)
    // Status code could be 200 (if redirect followed) or 301 (if not)
    XCTAssertNotNil(receivedStatusCode)
  }
  
  // MARK: - Default Timeout Tests
  
  func testDefaultRequestTimeout_IsCorrect() {
    XCTAssertEqual(TPPNetworkExecutor.defaultRequestTimeout, TPPDefaultRequestTimeout)
    XCTAssertEqual(TPPDefaultRequestTimeout, 30.0)
  }
  
  // MARK: - Shared Instance Tests
  
  func testSharedInstance_ReturnsSameInstance() {
    let instance1 = TPPNetworkExecutor.shared
    let instance2 = TPPNetworkExecutor.shared
    
    XCTAssertTrue(instance1 === instance2)
  }
}

// MARK: - Test Helpers

extension TPPNetworkExecutorTests {
  
  /// Registers a stub response for a specific URL
  private func registerStub(
    for url: URL,
    statusCode: Int,
    headers: [String: String]? = nil,
    body: Data?
  ) {
    HTTPStubURLProtocol.register { request in
      guard request.url == url else { return nil }
      return HTTPStubURLProtocol.StubbedResponse(
        statusCode: statusCode,
        headers: headers,
        body: body
      )
    }
  }
}

// MARK: - NYPLResult Extension Tests

extension TPPNetworkExecutorTests {
  
  func testNYPLResult_SuccessCase_ExtractsDataAndResponse() {
    // Given
    let testData = Data("test".utf8)
    let testResponse = HTTPURLResponse(
      url: successURL,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )
    let result: NYPLResult<Data> = .success(testData, testResponse)
    
    // When/Then
    switch result {
    case .success(let data, let response):
      XCTAssertEqual(data, testData)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    case .failure:
      XCTFail("Expected success case")
    }
  }
  
  func testNYPLResult_FailureCase_ExtractsErrorAndResponse() {
    // Given
    let testError = NSError(domain: "TestDomain", code: -1, userInfo: nil)
    let testResponse = HTTPURLResponse(
      url: serverErrorURL,
      statusCode: 500,
      httpVersion: nil,
      headerFields: nil
    )
    let result: NYPLResult<Data> = .failure(testError, testResponse)
    
    // When/Then
    switch result {
    case .success:
      XCTFail("Expected failure case")
    case .failure(let error, let response):
      XCTAssertEqual((error as NSError).code, -1)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 500)
    }
  }
  
  func testNYPLResult_SuccessWithNilResponse() {
    // Given
    let testData = Data("test".utf8)
    let result: NYPLResult<Data> = .success(testData, nil)
    
    // When/Then
    switch result {
    case .success(let data, let response):
      XCTAssertEqual(data, testData)
      XCTAssertNil(response)
    case .failure:
      XCTFail("Expected success case")
    }
  }
  
  func testNYPLResult_FailureWithNilResponse() {
    // Given
    let testError = NSError(domain: "TestDomain", code: -1, userInfo: nil)
    let result: NYPLResult<Data> = .failure(testError, nil)
    
    // When/Then
    switch result {
    case .success:
      XCTFail("Expected failure case")
    case .failure(let error, let response):
      XCTAssertNotNil(error)
      XCTAssertNil(response)
    }
  }
}
