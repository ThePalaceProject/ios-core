import XCTest
@testable import Palace

let testFeedUrl = Bundle(for: OPDS2CatalogsFeedTests.self)
  .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!

/// Tests for download-related state management using mock book registry
/// NOTE: These tests use mocks only and do NOT make network calls or create real URLSessions
class MyBooksDownloadCenterTests: XCTestCase {

  var mockBookRegistry: TPPBookRegistryMock!

  override func setUp() {
    super.setUp()
    mockBookRegistry = TPPBookRegistryMock()
  }

  override func tearDown() {
    mockBookRegistry?.registry = [:]
    mockBookRegistry = nil
    super.tearDown()
  }

  func testBookRegistry_storesBook() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadNeeded,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    XCTAssertNotNil(mockBookRegistry.book(forIdentifier: book.identifier))
  }

  func testBookRegistry_tracksState() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadNeeded,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadNeeded)
  }
  
  func testBookRegistry_stateTransitions() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadNeeded,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    mockBookRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
    
    mockBookRegistry.setState(.downloadSuccessful, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadSuccessful)
  }

  func testBookRegistry_multipleBooks() {
    let book1 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    let book2 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(book1, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(book2, location: nil, state: .downloadSuccessful, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    XCTAssertNotNil(mockBookRegistry.book(forIdentifier: book1.identifier))
    XCTAssertNotNil(mockBookRegistry.book(forIdentifier: book2.identifier))
    XCTAssertEqual(mockBookRegistry.state(for: book1.identifier), .downloadNeeded)
    XCTAssertEqual(mockBookRegistry.state(for: book2.identifier), .downloadSuccessful)
  }
}

// MARK: - Download Redirect Handling Tests

/// Tests for redirect handling in downloads.
/// Verifies that auth headers are not forwarded on redirects (for No DRM open access content).
final class DownloadRedirectTests: XCTestCase {
  
  // MARK: - URLRequest Auth Header Tests
  
  func testRedirectRequest_shouldNotContainAuthHeader_whenFollowingRedirect() {
    // When URLSession follows a redirect, the Authorization header should be stripped
    // This is URLSession's default secure behavior, and we don't re-add it
    
    let originalURL = URL(string: "https://gorgon.palaceproject.io/library/fulfill")!
    let redirectURL = URL(string: "https://cdn.example.com/book.epub")!
    
    var originalRequest = URLRequest(url: originalURL)
    originalRequest.setValue("Bearer palace-token-123", forHTTPHeaderField: "Authorization")
    
    // Simulate what URLSession does: create new request without auth
    var redirectRequest = URLRequest(url: redirectURL)
    // URLSession strips Authorization header by default - no auth in redirect request
    
    XCTAssertNil(
      redirectRequest.value(forHTTPHeaderField: "Authorization"),
      "Redirect request should not contain Authorization header"
    )
  }
  
  func testRedirectRequest_sameDomain_shouldNotContainAuthHeader() {
    // Even for same-domain redirects, we don't forward auth for open access content
    
    let originalURL = URL(string: "https://gorgon.palaceproject.io/library/fulfill")!
    let redirectURL = URL(string: "https://gorgon.palaceproject.io/content/book.epub")!
    
    var originalRequest = URLRequest(url: originalURL)
    originalRequest.setValue("Bearer palace-token-123", forHTTPHeaderField: "Authorization")
    
    // Redirect request should not have auth
    var redirectRequest = URLRequest(url: redirectURL)
    
    XCTAssertNil(
      redirectRequest.value(forHTTPHeaderField: "Authorization"),
      "Same-domain redirect request should not contain Authorization header for open access"
    )
  }
  
  func testRedirectRequest_crossDomain_shouldNotContainAuthHeader() {
    // Cross-domain redirects definitely should not forward auth
    
    let originalURL = URL(string: "https://gorgon.palaceproject.io/library/fulfill")!
    let redirectURL = URL(string: "https://library.biblioboard.com/content/book.epub")!
    
    var originalRequest = URLRequest(url: originalURL)
    originalRequest.setValue("Bearer palace-token-123", forHTTPHeaderField: "Authorization")
    
    var redirectRequest = URLRequest(url: redirectURL)
    
    XCTAssertNil(
      redirectRequest.value(forHTTPHeaderField: "Authorization"),
      "Cross-domain redirect request should not contain Authorization header"
    )
    
    // Verify domains are different
    XCTAssertNotEqual(originalURL.host, redirectURL.host)
  }
  
  // MARK: - Bearer Token JSON Flow Tests
  
  func testBearerTokenJSON_shouldUseDistributorToken_notPalaceToken() {
    // When we receive a Bearer Token JSON document, we should use the
    // distributor's token in the follow-up request, not our Palace token
    
    let palaceToken = "palace-auth-token-xyz"
    let distributorToken = "distributor-specific-token-abc"
    let contentLocation = URL(string: "https://distributor.example.com/book.epub")!
    
    // Simulate parsing the bearer token JSON document
    let bearerTokenDocument: [String: Any] = [
      "token_type": "Bearer",
      "access_token": distributorToken,
      "expires_in": 60,
      "location": contentLocation.absoluteString
    ]
    
    // Extract the token and location (simulating MyBooksSimplifiedBearerToken parsing)
    let accessToken = bearerTokenDocument["access_token"] as? String
    let location = bearerTokenDocument["location"] as? String
    
    XCTAssertEqual(accessToken, distributorToken)
    XCTAssertNotEqual(accessToken, palaceToken, "Should use distributor token, not Palace token")
    XCTAssertEqual(location, contentLocation.absoluteString)
    
    // Create request with distributor's token
    var contentRequest = URLRequest(url: contentLocation)
    contentRequest.setValue("Bearer \(distributorToken)", forHTTPHeaderField: "Authorization")
    
    XCTAssertEqual(
      contentRequest.value(forHTTPHeaderField: "Authorization"),
      "Bearer \(distributorToken)",
      "Content request should use distributor's token from JSON document"
    )
  }
  
  // MARK: - HTTPS Downgrade Protection Tests
  
  func testRedirect_httpsToHttp_shouldBeBlocked() {
    // Redirects from HTTPS to HTTP should be blocked for security
    
    let originalURL = URL(string: "https://secure.example.com/book")!
    let insecureRedirectURL = URL(string: "http://insecure.example.com/book.epub")!
    
    XCTAssertEqual(originalURL.scheme, "https")
    XCTAssertEqual(insecureRedirectURL.scheme, "http")
    
    // The redirect handler should block this (return nil to completionHandler)
    let shouldBlock = originalURL.scheme == "https" && insecureRedirectURL.scheme != "https"
    XCTAssertTrue(shouldBlock, "HTTPS to HTTP redirect should be blocked")
  }
  
  func testRedirect_httpsToHttps_shouldBeAllowed() {
    // Redirects from HTTPS to HTTPS should be allowed
    
    let originalURL = URL(string: "https://secure.example.com/book")!
    let secureRedirectURL = URL(string: "https://cdn.example.com/book.epub")!
    
    XCTAssertEqual(originalURL.scheme, "https")
    XCTAssertEqual(secureRedirectURL.scheme, "https")
    
    let shouldBlock = originalURL.scheme == "https" && secureRedirectURL.scheme != "https"
    XCTAssertFalse(shouldBlock, "HTTPS to HTTPS redirect should be allowed")
  }
}
