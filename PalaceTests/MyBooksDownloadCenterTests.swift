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
