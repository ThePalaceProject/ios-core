//
//  DefaultCatalogAPITests.swift
//  PalaceTests
//
//  Tests for DefaultCatalogAPI using NetworkClientMock.
//  These tests verify the real production class behavior with mocked network dependencies.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class DefaultCatalogAPITests: XCTestCase {

  // MARK: - Properties

  private var networkClientMock: NetworkClientMock!
  private var parser: OPDSParser!
  private var sut: DefaultCatalogAPI!

  // MARK: - Setup/Teardown

  override func setUp() {
    super.setUp()
    networkClientMock = NetworkClientMock()
    parser = OPDSParser()
    sut = DefaultCatalogAPI(client: networkClientMock, parser: parser)
  }

  override func tearDown() {
    networkClientMock = nil
    parser = nil
    sut = nil
    super.tearDown()
  }

  // MARK: - fetchFeed Tests

  func testFetchFeed_ValidOPDSResponse_ReturnsParsedFeed() async throws {
    // Arrange
    let testURL = URL(string: "https://example.com/catalog")!
    let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Test Catalog", entries: 3)
    networkClientMock.stubOPDSResponse(for: testURL, xml: opdsXML)

    // Act
    let feed = try await sut.fetchFeed(at: testURL)

    // Assert
    XCTAssertNotNil(feed)
    XCTAssertEqual(feed?.title, "Test Catalog")
    XCTAssertEqual(feed?.entries.count, 3)
    XCTAssertEqual(networkClientMock.sendCallCount, 1)
    XCTAssertEqual(networkClientMock.lastRequestedURL, testURL)
    XCTAssertEqual(networkClientMock.lastRequestedMethod, .GET)
  }

  func testFetchFeed_EmptyFeed_ReturnsEmptyEntries() async throws {
    // Arrange
    let testURL = URL(string: "https://example.com/empty-catalog")!
    let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Empty Catalog", entries: 0)
    networkClientMock.stubOPDSResponse(for: testURL, xml: opdsXML)

    // Act
    let feed = try await sut.fetchFeed(at: testURL)

    // Assert
    XCTAssertNotNil(feed)
    XCTAssertEqual(feed?.title, "Empty Catalog")
    XCTAssertTrue(feed?.entries.isEmpty ?? false)
  }

  func testFetchFeed_NetworkError_ThrowsError() async {
    // Arrange
    let testURL = URL(string: "https://example.com/error")!
    networkClientMock.errorsByURL[testURL] = NetworkClientMockError.networkUnavailable

    // Act & Assert
    do {
      _ = try await sut.fetchFeed(at: testURL)
      XCTFail("Expected error to be thrown")
    } catch {
      XCTAssertTrue(networkClientMock.wasURLRequested(testURL))
      XCTAssertEqual(networkClientMock.sendCallCount, 1)
    }
  }

  func testFetchFeed_InvalidXML_ThrowsParsingError() async {
    // Arrange
    let testURL = URL(string: "https://example.com/invalid")!
    networkClientMock.stubOPDSResponse(for: testURL, xml: "not valid xml at all <><>")

    // Act & Assert
    do {
      _ = try await sut.fetchFeed(at: testURL)
      XCTFail("Expected parsing error to be thrown")
    } catch {
      // Parser should throw an error for invalid XML
      XCTAssertTrue(networkClientMock.wasURLRequested(testURL))
    }
  }

  func testFetchFeed_Timeout_ThrowsError() async {
    // Arrange
    let testURL = URL(string: "https://example.com/slow")!
    networkClientMock.errorsByURL[testURL] = NetworkClientMockError.timeout

    // Act & Assert
    do {
      _ = try await sut.fetchFeed(at: testURL)
      XCTFail("Expected timeout error to be thrown")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("timed out") ||
                   error is NetworkClientMockError)
    }
  }

  func testFetchFeed_UsesGETMethod() async throws {
    // Arrange
    let testURL = URL(string: "https://example.com/catalog")!
    let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Test")
    networkClientMock.stubOPDSResponse(for: testURL, xml: opdsXML)

    // Act
    _ = try await sut.fetchFeed(at: testURL)

    // Assert
    XCTAssertTrue(networkClientMock.wasMethodUsed(.GET, forURL: testURL))
  }

  func testFetchFeed_MultipleCalls_TracksAllRequests() async throws {
    // Arrange
    let url1 = URL(string: "https://example.com/catalog1")!
    let url2 = URL(string: "https://example.com/catalog2")!
    let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Test")
    networkClientMock.stubOPDSResponse(for: url1, xml: opdsXML)
    networkClientMock.stubOPDSResponse(for: url2, xml: opdsXML)

    // Act
    _ = try await sut.fetchFeed(at: url1)
    _ = try await sut.fetchFeed(at: url2)

    // Assert
    XCTAssertEqual(networkClientMock.sendCallCount, 2)
    XCTAssertTrue(networkClientMock.wasURLRequested(url1))
    XCTAssertTrue(networkClientMock.wasURLRequested(url2))
    XCTAssertEqual(networkClientMock.requestHistory.count, 2)
  }

  // MARK: - Error Injection Tests

  func testFetchFeed_ServerError500_ThrowsError() async {
    // Arrange
    let testURL = URL(string: "https://example.com/server-error")!
    networkClientMock.errorsByURL[testURL] = NetworkClientMockError.serverError(500)

    // Act & Assert
    do {
      _ = try await sut.fetchFeed(at: testURL)
      XCTFail("Expected server error to be thrown")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("500") ||
                   error is NetworkClientMockError)
    }
  }

  func testFetchFeed_UnauthorizedError_ThrowsError() async {
    // Arrange
    let testURL = URL(string: "https://example.com/protected")!
    networkClientMock.errorsByURL[testURL] = NetworkClientMockError.unauthorized

    // Act & Assert
    do {
      _ = try await sut.fetchFeed(at: testURL)
      XCTFail("Expected unauthorized error to be thrown")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Authentication") ||
                   error is NetworkClientMockError)
    }
  }

  func testFetchFeed_GlobalError_AffectsAllRequests() async {
    // Arrange
    let testURL = URL(string: "https://example.com/catalog")!
    networkClientMock.errorToThrow = NetworkClientMockError.networkUnavailable

    // Act & Assert
    do {
      _ = try await sut.fetchFeed(at: testURL)
      XCTFail("Expected global error to be thrown")
    } catch {
      XCTAssertTrue(error is NetworkClientMockError)
    }
  }

  // MARK: - Call Tracking Tests

  func testFetchFeed_TracksRequestDetails() async throws {
    // Arrange
    let testURL = URL(string: "https://example.com/catalog?page=1")!
    let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Test")
    networkClientMock.stubOPDSResponse(for: testURL, xml: opdsXML)

    // Act
    _ = try await sut.fetchFeed(at: testURL)

    // Assert
    XCTAssertNotNil(networkClientMock.lastRequest)
    XCTAssertEqual(networkClientMock.lastRequest?.url, testURL)
    XCTAssertEqual(networkClientMock.lastRequest?.method, .GET)
  }

  func testFetchFeed_AfterReset_CallCountResetsToZero() async throws {
    // Arrange
    let testURL = URL(string: "https://example.com/catalog")!
    let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Test")
    networkClientMock.stubOPDSResponse(for: testURL, xml: opdsXML)

    // Act - make some calls
    _ = try await sut.fetchFeed(at: testURL)
    _ = try await sut.fetchFeed(at: testURL)
    XCTAssertEqual(networkClientMock.sendCallCount, 2)

    // Reset the mock
    networkClientMock.reset()
    networkClientMock.stubOPDSResponse(for: testURL, xml: opdsXML)

    // Assert - call count should be reset
    XCTAssertEqual(networkClientMock.sendCallCount, 0)
    XCTAssertNil(networkClientMock.lastRequest)
    XCTAssertTrue(networkClientMock.requestHistory.isEmpty)

    // Make another call
    _ = try await sut.fetchFeed(at: testURL)
    XCTAssertEqual(networkClientMock.sendCallCount, 1)
  }

  // MARK: - Response Stubbing Tests

  func testFetchFeed_DifferentURLs_ReturnDifferentStubs() async throws {
    // Arrange
    let url1 = URL(string: "https://example.com/fiction")!
    let url2 = URL(string: "https://example.com/nonfiction")!
    networkClientMock.stubOPDSResponse(
      for: url1,
      xml: NetworkClientMock.makeOPDSFeedXML(title: "Fiction", entries: 2)
    )
    networkClientMock.stubOPDSResponse(
      for: url2,
      xml: NetworkClientMock.makeOPDSFeedXML(title: "Non-Fiction", entries: 5)
    )

    // Act
    let feed1 = try await sut.fetchFeed(at: url1)
    let feed2 = try await sut.fetchFeed(at: url2)

    // Assert
    XCTAssertEqual(feed1?.title, "Fiction")
    XCTAssertEqual(feed1?.entries.count, 2)
    XCTAssertEqual(feed2?.title, "Non-Fiction")
    XCTAssertEqual(feed2?.entries.count, 5)
  }

  func testFetchFeed_DefaultResponse_UsedWhenNoStubSet() async throws {
    // Arrange
    let testURL = URL(string: "https://example.com/unstubbed")!
    let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Default Feed")
    let data = Data(opdsXML.utf8)
    let httpResponse = HTTPURLResponse(
      url: testURL,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/atom+xml"]
    )!
    networkClientMock.defaultResponse = NetworkResponse(data: data, response: httpResponse)

    // Act
    let feed = try await sut.fetchFeed(at: testURL)

    // Assert
    XCTAssertNotNil(feed)
    XCTAssertEqual(feed?.title, "Default Feed")
  }

  // MARK: - Edge Cases

  func testFetchFeed_EmptyResponseData_ThrowsParsingError() async {
    // Arrange
    let testURL = URL(string: "https://example.com/empty")!
    networkClientMock.stubOPDSResponse(for: testURL, xml: "")

    // Act & Assert
    do {
      _ = try await sut.fetchFeed(at: testURL)
      XCTFail("Expected parsing error for empty response")
    } catch {
      // Parser should fail on empty data
      XCTAssertTrue(networkClientMock.wasURLRequested(testURL))
    }
  }

  func testFetchFeed_URLWithQueryParameters_PreservesParameters() async throws {
    // Arrange
    let testURL = URL(string: "https://example.com/catalog?page=2&sort=title")!
    let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Page 2")
    networkClientMock.stubOPDSResponse(for: testURL, xml: opdsXML)

    // Act
    _ = try await sut.fetchFeed(at: testURL)

    // Assert
    XCTAssertEqual(networkClientMock.lastRequestedURL?.query, "page=2&sort=title")
  }

  func testFetchFeed_SpecialCharactersInFeedTitle_ParsesCorrectly() async throws {
    // Arrange
    let testURL = URL(string: "https://example.com/catalog")!
    let opdsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <id>urn:uuid:test</id>
      <title>Books &amp; More: A "Special" Collection</title>
      <updated>2024-01-01T00:00:00Z</updated>
    </feed>
    """
    networkClientMock.stubOPDSResponse(for: testURL, xml: opdsXML)

    // Act
    let feed = try await sut.fetchFeed(at: testURL)

    // Assert
    XCTAssertNotNil(feed)
    XCTAssertEqual(feed?.title, "Books & More: A \"Special\" Collection")
  }

  // MARK: - Simulated Network Conditions

  func testFetchFeed_FailAfterMultipleCalls_SimulatesIntermittentFailure() async throws {
    // Arrange
    let testURL = URL(string: "https://example.com/catalog")!
    let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Test")
    networkClientMock.stubOPDSResponse(for: testURL, xml: opdsXML)
    networkClientMock.failAfterCallCount = 2

    // Act - first two calls should succeed
    _ = try await sut.fetchFeed(at: testURL)
    _ = try await sut.fetchFeed(at: testURL)

    // Assert - third call should fail
    do {
      _ = try await sut.fetchFeed(at: testURL)
      XCTFail("Expected failure after 2 calls")
    } catch {
      XCTAssertEqual(networkClientMock.sendCallCount, 3)
    }
  }
}

// MARK: - Integration with CatalogRepository Tests

extension DefaultCatalogAPITests {

  /// Tests that DefaultCatalogAPI works correctly when used by CatalogRepository
  func testCatalogAPI_IntegrationWithRepository_WorksCorrectly() async throws {
    // Arrange
    let testURL = URL(string: "https://example.com/catalog")!
    let opdsXML = NetworkClientMock.makeOPDSFeedXML(title: "Library Catalog", entries: 5)
    networkClientMock.stubOPDSResponse(for: testURL, xml: opdsXML)

    let repository = CatalogRepository(api: sut)

    // Act
    let feed = try await repository.fetchFeed(at: testURL)

    // Assert
    XCTAssertNotNil(feed)
    XCTAssertEqual(feed?.title, "Library Catalog")
    XCTAssertEqual(feed?.entries.count, 5)

    // Verify network was called
    XCTAssertEqual(networkClientMock.sendCallCount, 1)
  }

  /// Tests that CatalogRepository handles API errors correctly
  func testCatalogAPI_IntegrationWithRepository_HandlesErrors() async {
    // Arrange
    let testURL = URL(string: "https://example.com/error")!
    networkClientMock.errorToThrow = NetworkClientMockError.networkUnavailable

    let repository = CatalogRepository(api: sut)

    // Act & Assert
    do {
      _ = try await repository.loadTopLevelCatalog(at: testURL)
      XCTFail("Expected error to propagate through repository")
    } catch {
      // Error should propagate up
      XCTAssertEqual(networkClientMock.sendCallCount, 1)
    }
  }
}
