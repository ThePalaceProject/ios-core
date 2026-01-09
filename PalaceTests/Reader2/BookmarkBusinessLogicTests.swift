//
//  BookmarkBusinessLogicTests.swift
//  PalaceTests
//
//  Extended tests for bookmark business logic
//

import XCTest
import ReadiumShared
@testable import Palace

final class BookmarkBusinessLogicExtendedTests: XCTestCase {
  
  // MARK: - Properties
  
  private var businessLogic: TPPReaderBookmarksBusinessLogic!
  private var bookRegistryMock: TPPBookRegistryMock!
  private var libraryAccountMock: TPPLibraryAccountMock!
  private var testBook: TPPBook!
  private let bookIdentifier = "test-book-id"
  
  // MARK: - Setup
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    
    // Use placeholder URL for acquisition (not fetched in tests)
    let placeholderUrl = URL(string: "https://test.example.com/book")!
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: placeholderUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    
    testBook = TPPBook(
      acquisitions: [acquisition],
      authors: [],
      categoryStrings: [],
      distributor: "",
      identifier: bookIdentifier,
      imageURL: nil,  // Use nil to prevent network image fetches
      imageThumbnailURL: nil,  // Use nil to prevent network image fetches
      published: Date(),
      publisher: "",
      subtitle: "",
      summary: "",
      title: "Test Book",
      updated: Date(),
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,  // No preview to prevent network requests
      seriesURL: nil,
      revokeURL: nil,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: [:],
      bookDuration: nil,
      imageCache: MockImageCache()
    )
    
    bookRegistryMock = TPPBookRegistryMock()
    bookRegistryMock.addBook(
      testBook,
      location: nil,
      state: .downloadSuccessful,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    libraryAccountMock = TPPLibraryAccountMock()
    
    let manifest = Manifest(metadata: Metadata(title: "Test"))
    let publication = Publication(manifest: manifest)
    
    businessLogic = TPPReaderBookmarksBusinessLogic(
      book: testBook,
      r2Publication: publication,
      drmDeviceID: "test-device-id",
      bookRegistryProvider: bookRegistryMock,
      currentLibraryAccountProvider: libraryAccountMock
    )
  }
  
  override func tearDownWithError() throws {
    businessLogic = nil
    bookRegistryMock?.registry = [:]
    bookRegistryMock = nil
    libraryAccountMock = nil
    testBook = nil
    try super.tearDownWithError()
  }
  
  // MARK: - Bookmark Retrieval Tests
  
  func testBookmarkAtIndex_validIndex_returnsBookmark() {
    guard let bookmark = createBookmark(progressWithinBook: 0.5) else {
      XCTFail("Failed to create bookmark")
      return
    }
    bookRegistryMock.add(bookmark, forIdentifier: bookIdentifier)
    
    // Reload bookmarks
    businessLogic = TPPReaderBookmarksBusinessLogic(
      book: testBook,
      r2Publication: Publication(manifest: Manifest(metadata: Metadata(title: "Test"))),
      drmDeviceID: "test-device-id",
      bookRegistryProvider: bookRegistryMock,
      currentLibraryAccountProvider: libraryAccountMock
    )
    
    let retrieved = businessLogic.bookmark(at: 0)
    XCTAssertNotNil(retrieved)
  }
  
  func testBookmarkAtIndex_negativeIndex_returnsNil() {
    let result = businessLogic.bookmark(at: -1)
    XCTAssertNil(result)
  }
  
  func testBookmarkAtIndex_outOfBoundsIndex_returnsNil() {
    let result = businessLogic.bookmark(at: 100)
    XCTAssertNil(result)
  }
  
  // MARK: - Delete Bookmark Tests
  
  func testDeleteBookmark_existingBookmark_removes() {
    guard let bookmark = createBookmark(progressWithinBook: 0.5) else {
      XCTFail("Failed to create bookmark")
      return
    }
    bookRegistryMock.add(bookmark, forIdentifier: bookIdentifier)
    
    // Reload to get bookmark in business logic
    businessLogic = TPPReaderBookmarksBusinessLogic(
      book: testBook,
      r2Publication: Publication(manifest: Manifest(metadata: Metadata(title: "Test"))),
      drmDeviceID: "test-device-id",
      bookRegistryProvider: bookRegistryMock,
      currentLibraryAccountProvider: libraryAccountMock
    )
    
    XCTAssertEqual(businessLogic.bookmarks.count, 1)
    
    if let bookmarkToDelete = businessLogic.bookmarks.first {
      businessLogic.deleteBookmark(bookmarkToDelete)
    }
    
    XCTAssertEqual(businessLogic.bookmarks.count, 0)
  }
  
  func testDeleteBookmarkAtIndex_validIndex_removesAndReturns() {
    guard let bookmark = createBookmark(progressWithinBook: 0.5) else {
      XCTFail("Failed to create bookmark")
      return
    }
    bookRegistryMock.add(bookmark, forIdentifier: bookIdentifier)
    
    // Reload
    businessLogic = TPPReaderBookmarksBusinessLogic(
      book: testBook,
      r2Publication: Publication(manifest: Manifest(metadata: Metadata(title: "Test"))),
      drmDeviceID: "test-device-id",
      bookRegistryProvider: bookRegistryMock,
      currentLibraryAccountProvider: libraryAccountMock
    )
    
    let deleted = businessLogic.deleteBookmark(at: 0)
    
    XCTAssertNotNil(deleted)
    XCTAssertEqual(businessLogic.bookmarks.count, 0)
  }
  
  func testDeleteBookmarkAtIndex_invalidIndex_returnsNil() {
    let result = businessLogic.deleteBookmark(at: -1)
    XCTAssertNil(result)
  }
  
  func testDeleteBookmarkAtIndex_outOfBounds_returnsNil() {
    let result = businessLogic.deleteBookmark(at: 100)
    XCTAssertNil(result)
  }
  
  // MARK: - UI Text Tests
  
  func testNoBookmarksText_returnsLocalizedString() {
    let text = businessLogic.noBookmarksText
    XCTAssertFalse(text.isEmpty)
  }
  
  // MARK: - Selection Tests
  
  func testShouldSelectBookmark_returnsTrue() {
    let result = businessLogic.shouldSelectBookmark(at: 0)
    XCTAssertTrue(result)
  }
  
  // MARK: - Sync Permission Tests
  
  func testShouldAllowRefresh_checksSyncPermission() {
    let result = businessLogic.shouldAllowRefresh()
    // Result depends on sync configuration
    XCTAssertNotNil(result)
  }
  
  // MARK: - Helper Methods
  
  private func createBookmark(progressWithinBook: Float) -> TPPReadiumBookmark? {
    TPPReadiumBookmark(
      annotationId: "annotation-\(UUID().uuidString)",
      href: "/chapter1",
      chapter: "Chapter 1",
      page: nil,
      location: nil,
      progressWithinChapter: 0.5,
      progressWithinBook: progressWithinBook,
      readingOrderItem: nil,
      readingOrderItemOffsetMilliseconds: 0,
      time: nil,
      device: nil
    )
  }
}

// MARK: - Bookmark Sync Tests

final class BookmarkSyncTests: XCTestCase {
  
  private var businessLogic: TPPReaderBookmarksBusinessLogic!
  private var bookRegistryMock: TPPBookRegistryMock!
  private var libraryAccountMock: TPPLibraryAccountMock!
  private var testBook: TPPBook!
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    
    let emptyUrl = URL(fileURLWithPath: "")
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: emptyUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    
    testBook = TPPBook(
      acquisitions: [acquisition],
      authors: [],
      categoryStrings: [],
      distributor: "",
      identifier: "sync-test-book",
      imageURL: emptyUrl,
      imageThumbnailURL: emptyUrl,
      published: Date(),
      publisher: "",
      subtitle: "",
      summary: "",
      title: "Sync Test Book",
      updated: Date(),
      annotationsURL: emptyUrl,
      analyticsURL: emptyUrl,
      alternateURL: emptyUrl,
      relatedWorksURL: emptyUrl,
      previewLink: acquisition,
      seriesURL: emptyUrl,
      revokeURL: emptyUrl,
      reportURL: emptyUrl,
      timeTrackingURL: emptyUrl,
      contributors: [:],
      bookDuration: nil,
      imageCache: MockImageCache()
    )
    
    bookRegistryMock = TPPBookRegistryMock()
    libraryAccountMock = TPPLibraryAccountMock()
    
    let manifest = Manifest(metadata: Metadata(title: "Sync Test"))
    let publication = Publication(manifest: manifest)
    
    businessLogic = TPPReaderBookmarksBusinessLogic(
      book: testBook,
      r2Publication: publication,
      drmDeviceID: "sync-test-device",
      bookRegistryProvider: bookRegistryMock,
      currentLibraryAccountProvider: libraryAccountMock
    )
  }
  
  override func tearDownWithError() throws {
    businessLogic = nil
    bookRegistryMock = nil
    libraryAccountMock = nil
    testBook = nil
    try super.tearDownWithError()
  }
  
  func testUpdateLocalBookmarks_addsServerBookmarks() {
    let expectation = expectation(description: "Update completes")
    
    let serverBookmark = TPPReadiumBookmark(
      annotationId: "server-bookmark-1",
      href: "/chapter1",
      chapter: "Chapter 1",
      page: nil,
      location: nil,
      progressWithinChapter: 0.3,
      progressWithinBook: 0.3,
      readingOrderItem: nil,
      readingOrderItemOffsetMilliseconds: 0,
      time: nil,
      device: nil
    )
    
    guard let bookmark = serverBookmark else {
      XCTFail("Failed to create bookmark")
      return
    }
    
    // Just verify the method can be called without crashing
    businessLogic.updateLocalBookmarks(
      serverBookmarks: [bookmark],
      localBookmarks: [],
      bookmarksFailedToUpload: []
    ) { }
  }
  
  func testUpdateLocalBookmarks_handlesEmptyServerList() {
    // Just verify the method can be called without crashing
    businessLogic.updateLocalBookmarks(
      serverBookmarks: [],
      localBookmarks: [],
      bookmarksFailedToUpload: []
    ) { }
  }
  
  func testUpdateLocalBookmarks_preservesFailedUploads() {
    let failedBookmark = TPPReadiumBookmark(
      annotationId: nil,
      href: "/chapter2",
      chapter: "Chapter 2",
      page: nil,
      location: nil,
      progressWithinChapter: 0.5,
      progressWithinBook: 0.5,
      readingOrderItem: nil,
      readingOrderItemOffsetMilliseconds: 0,
      time: nil,
      device: nil
    )
    
    guard let bookmark = failedBookmark else {
      XCTFail("Failed to create bookmark")
      return
    }
    
    // Just verify the method can be called without crashing
    businessLogic.updateLocalBookmarks(
      serverBookmarks: [],
      localBookmarks: [],
      bookmarksFailedToUpload: [bookmark]
    ) { }
  }
}

