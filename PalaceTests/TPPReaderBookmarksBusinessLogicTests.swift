//
//  NYPLReaderBookmarkBusinessLogicTests.swift
//  The Palace Project
//
//  Created by Ernest Fan on 2020-10-29.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import XCTest
import ReadiumShared
@testable import Palace

class TPPReaderBookmarksBusinessLogicTests: XCTestCase {
    var bookmarkBusinessLogic: TPPReaderBookmarksBusinessLogic!
    var bookRegistryMock: TPPBookRegistryMock!
    var libraryAccountMock: TPPLibraryAccountMock!
    var bookmarkCounter: Int = 0
    let bookIdentifier = "fakeEpub"
    
    override func setUpWithError() throws {
      try super.setUpWithError()
      
      // Use placeholder URL for acquisition (not fetched in tests)
      let placeholderUrl = URL(string: "https://test.example.com/book")!
      let fakeAcquisition = TPPOPDSAcquisition(
        relation: .generic,
        type: "application/epub+zip",
        hrefURL: placeholderUrl,
        indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
        availability: TPPOPDSAcquisitionAvailabilityUnlimited()
      )
      
      let fakeBook = TPPBook(
        acquisitions: [fakeAcquisition],
        authors: [TPPBookAuthor](),
        categoryStrings: [String](),
        distributor: "",
        identifier: bookIdentifier,
        imageURL: nil,  // Use nil to prevent network image fetches
        imageThumbnailURL: nil,  // Use nil to prevent network image fetches
        published: Date(),
        publisher: "",
        subtitle: "",
        summary: "",
        title: "",
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
      bookRegistryMock.addBook(fakeBook, location: nil, state: .downloadSuccessful, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
      libraryAccountMock = TPPLibraryAccountMock()
      let manifest = Manifest(metadata: Metadata(title: "fakeMetadata"))
      let pub = Publication(manifest: manifest)
      bookmarkBusinessLogic = TPPReaderBookmarksBusinessLogic(
        book: fakeBook,
        r2Publication: pub,
        drmDeviceID: "fakeDeviceID",
        bookRegistryProvider: bookRegistryMock,
        currentLibraryAccountProvider: libraryAccountMock)
      bookmarkCounter = 0
    }

    override func tearDownWithError() throws {
      try super.tearDownWithError()
      bookmarkBusinessLogic = nil
      libraryAccountMock = nil
      bookRegistryMock?.registry  = [:]
      bookRegistryMock = nil
      bookmarkCounter = 0
    }

    // MARK: - Test updateLocalBookmarks
    
    func testUpdateLocalBookmarksWithNoLocalBookmarks() throws {
      var serverBookmarks = [TPPReadiumBookmark]()
        
      // Make sure BookRegistry contains no bookmark
      XCTAssertEqual(bookRegistryMock.readiumBookmarks(forIdentifier: bookIdentifier).count, 0)
      
      guard let firstBookmark = newBookmark(href: "Intro",
                                          chapter: "1",
                                          progressWithinChapter: 0.1,
                                          progressWithinBook: 0.1) else {
        XCTFail("Failed to create new bookmark")
        return
      }
      serverBookmarks.append(firstBookmark)

      bookmarkBusinessLogic.updateLocalBookmarks(serverBookmarks: serverBookmarks,
                                                 localBookmarks: bookRegistryMock.readiumBookmarks(forIdentifier: bookIdentifier),
                                                 bookmarksFailedToUpload: [TPPReadiumBookmark]()) {
        XCTAssertEqual(self.bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier).count, 1)
      }
    }
    
    func testUpdateLocalBookmarksWithDuplicatedLocalBookmarks() throws {
      var serverBookmarks = [TPPReadiumBookmark]()

      // Make sure BookRegistry contains no bookmark
      XCTAssertEqual(bookRegistryMock.readiumBookmarks(forIdentifier: bookIdentifier).count, 0)
      
      guard let firstBookmark = newBookmark(href: "Intro",
                                          chapter: "1",
                                          progressWithinChapter: 0.1,
                                          progressWithinBook: 0.1),
        let secondBookmark = newBookmark(href: "Intro",
                                         chapter: "1",
                                         progressWithinChapter: 0.2,
                                         progressWithinBook: 0.1) else {
        XCTFail("Failed to create new bookmark")
        return
      }
        
      serverBookmarks.append(firstBookmark)
      serverBookmarks.append(secondBookmark)
      bookRegistryMock.add(firstBookmark, forIdentifier: bookIdentifier)
      XCTAssertEqual(self.bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier).count, 1)

      // There are one duplicated bookmark and one non-synced (server) bookmark
      bookmarkBusinessLogic.updateLocalBookmarks(serverBookmarks: serverBookmarks,
                                                 localBookmarks: bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier),
                                                 bookmarksFailedToUpload: [TPPReadiumBookmark]()) {
        XCTAssertEqual(self.bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier).count, 2)
      }
    }
    
    func testUpdateLocalBookmarksWithExtraLocalBookmarks() throws {
      var serverBookmarks = [TPPReadiumBookmark]()

      // Make sure BookRegistry contains no bookmark
      XCTAssertEqual(bookRegistryMock.readiumBookmarks(forIdentifier: bookIdentifier).count, 0)
      
      guard let firstBookmark = newBookmark(href: "Intro",
                                          chapter: "1",
                                          progressWithinChapter: 0.1,
                                          progressWithinBook: 0.1),
        let secondBookmark = newBookmark(href: "Intro",
                                         chapter: "1",
                                         progressWithinChapter: 0.2,
                                         progressWithinBook: 0.1) else {
        XCTFail("Failed to create new bookmark")
        return
      }
        
      serverBookmarks.append(firstBookmark)
      bookRegistryMock.add(firstBookmark, forIdentifier: bookIdentifier)
      bookRegistryMock.add(secondBookmark, forIdentifier: bookIdentifier)
      XCTAssertEqual(self.bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier).count, 2)

      // There are one duplicated bookmark and one (local) bookmark, there should be 2 bookmarks
      bookmarkBusinessLogic.updateLocalBookmarks(serverBookmarks: serverBookmarks,
                                                 localBookmarks: bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier),
                                                 bookmarksFailedToUpload: [TPPReadiumBookmark]()) {
        XCTAssertEqual(self.bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier).count, 2)
      }
    }
    
    func testUpdateLocalBookmarksWithFailedUploadBookmarks() throws {
      var serverBookmarks = [TPPReadiumBookmark]()

      // Make sure BookRegistry contains no bookmark
      XCTAssertEqual(bookRegistryMock.readiumBookmarks(forIdentifier: bookIdentifier).count, 0)
      
      guard let firstBookmark = newBookmark(href: "Intro",
                                          chapter: "1",
                                          progressWithinChapter: 0.1,
                                          progressWithinBook: 0.1),
        let secondBookmark = newBookmark(href: "Intro",
                                         chapter: "1",
                                         progressWithinChapter: 0.2,
                                         progressWithinBook: 0.1) else {
        XCTFail("Failed to create new bookmark")
        return
      }
        
      serverBookmarks.append(firstBookmark)
      bookRegistryMock.add(firstBookmark, forIdentifier: bookIdentifier)
      XCTAssertEqual(self.bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier).count, 1)
        
      // There are one duplicated bookmark and one failed-to-upload bookmark
      bookmarkBusinessLogic.updateLocalBookmarks(serverBookmarks: serverBookmarks,
                                                 localBookmarks: bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier),
                                                 bookmarksFailedToUpload: [secondBookmark]) {
        XCTAssertEqual(self.bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier).count, 2)
      }
    }

    // MARK: Helper
    
    func newBookmark(href: String,
                     chapter: String,
                     progressWithinChapter: Float,
                     progressWithinBook: Float,
                     device: String? = nil) -> TPPReadiumBookmark? {
      // Annotation id needs to be unique
      bookmarkCounter += 1
      return TPPReadiumBookmark(annotationId: "fakeAnnotationID\(bookmarkCounter)",
                                href: href,
                                 chapter: chapter,
                                 page: nil,
                                 location: nil,
                                 progressWithinChapter: progressWithinChapter,
                                 progressWithinBook: progressWithinBook,
                                 readingOrderItem: nil,
                                 readingOrderItemOffsetMilliseconds: 0,
                                 time:nil,
                                 device:device)
      
    }
    
    // MARK: - Regression Tests

    /// Regression test for Old bookmarks should not reappear after return/re-borrow
    /// When a user returns a book and later re-borrows it, old bookmarks from the server
    /// should NOT reappear because they should have been deleted during the return process.
    func testPP3555_OldBookmarksDoNotReappearAfterReborrow() throws {
      // 1. Arrange: Create a book with server bookmarks
      guard let serverBookmark1 = newBookmark(href: "Chapter1",
                                              chapter: "1",
                                              progressWithinChapter: 0.25,
                                              progressWithinBook: 0.1),
            let serverBookmark2 = newBookmark(href: "Chapter2",
                                              chapter: "2",
                                              progressWithinChapter: 0.5,
                                              progressWithinBook: 0.3) else {
        XCTFail("Failed to create test bookmarks")
        return
      }
      
      // Add bookmarks to the local registry (simulating initial borrow state)
      bookRegistryMock.add(serverBookmark1, forIdentifier: bookIdentifier)
      bookRegistryMock.add(serverBookmark2, forIdentifier: bookIdentifier)
      XCTAssertEqual(bookRegistryMock.readiumBookmarks(forIdentifier: bookIdentifier).count, 2,
                     "Should have 2 bookmarks before return")
      
      // Create annotation mock to simulate server with bookmarks
      let annotationMock = TPPAnnotationMock()
      
      // Simulate server having these bookmarks (as if they were previously synced)
      // Store them with their annotation IDs as server bookmarks
      annotationMock.readiumBookmarks[bookIdentifier] = [serverBookmark1, serverBookmark2]
      
      // 2. Act: Simulate return - delete all bookmarks from server, then remove from registry
      let deleteExpectation = expectation(description: "Delete all bookmarks")
      annotationMock.deleteAllBookmarks(forBook: bookRegistryMock.book(forIdentifier: bookIdentifier)!) {
        deleteExpectation.fulfill()
      }
      wait(for: [deleteExpectation], timeout: 1.0)
      
      // Remove book from registry (as happens during return)
      bookRegistryMock.removeBook(forIdentifier: bookIdentifier)
      
      // 3. Act: Re-borrow (add book fresh to registry with no bookmarks)
      let placeholderUrl = URL(string: "https://test.example.com/book")!
      let fakeAcquisition = TPPOPDSAcquisition(
        relation: .generic,
        type: "application/epub+zip",
        hrefURL: placeholderUrl,
        indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
        availability: TPPOPDSAcquisitionAvailabilityUnlimited()
      )
      
      let freshBook = TPPBook(
        acquisitions: [fakeAcquisition],
        authors: [TPPBookAuthor](),
        categoryStrings: [String](),
        distributor: "",
        identifier: bookIdentifier,
        imageURL: nil,
        imageThumbnailURL: nil,
        published: Date(),
        publisher: "",
        subtitle: "",
        summary: "",
        title: "Re-borrowed Book",
        updated: Date(),
        annotationsURL: URL(string: "https://test.example.com/annotations"),
        analyticsURL: nil,
        alternateURL: nil,
        relatedWorksURL: nil,
        previewLink: nil,
        seriesURL: nil,
        revokeURL: nil,
        reportURL: nil,
        timeTrackingURL: nil,
        contributors: [:],
        bookDuration: nil,
        imageCache: MockImageCache()
      )
      
      bookRegistryMock.addBook(freshBook, location: nil, state: .downloadSuccessful,
                               fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
      
      // 4. Assert: Server should have no bookmarks after return
      let syncExpectation = expectation(description: "Get server bookmarks")
      annotationMock.getServerBookmarks(forBook: freshBook, atURL: freshBook.annotationsURL, motivation: .bookmark) { bookmarks in
        // After return, server should have NO bookmarks for this book
        XCTAssertEqual(bookmarks?.count ?? 0, 0,
                       "Server should have no bookmarks after return - old bookmarks should have been deleted")
        syncExpectation.fulfill()
      }
      wait(for: [syncExpectation], timeout: 1.0)
      
      // 5. Assert: Local registry should have no bookmarks for the re-borrowed book
      XCTAssertEqual(bookRegistryMock.readiumBookmarks(forIdentifier: bookIdentifier).count, 0,
                     "Re-borrowed book should have no bookmarks locally")
    }
}
