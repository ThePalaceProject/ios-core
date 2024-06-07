//
//  NYPLReaderBookmarkBusinessLogicTests.swift
//  The Palace Project
//
//  Created by Ernest Fan on 2020-10-29.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import XCTest
import R2Shared
@testable import Palace

class TPPReaderBookmarksBusinessLogicTests: XCTestCase {
    var bookmarkBusinessLogic: TPPReaderBookmarksBusinessLogic!
    var bookRegistryMock: TPPBookRegistryMock!
    var libraryAccountMock: TPPLibraryAccountMock!
    var bookmarkCounter: Int = 0
    let bookIdentifier = "fakeEpub"
    
    override func setUpWithError() throws {
      try super.setUpWithError()
      
      let emptyUrl = URL.init(fileURLWithPath: "")
      let fakeAcquisition = TPPOPDSAcquisition.init(
        relation: .generic,
        type: "application/epub+zip",
        hrefURL: emptyUrl,
        indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
        availability: TPPOPDSAcquisitionAvailabilityUnlimited.init()
      )
      
      let fakeBook = TPPBook.init(
        acquisitions: [fakeAcquisition],
        authors: [TPPBookAuthor](),
        categoryStrings: [String](),
        distributor: "",
        identifier: bookIdentifier,
        imageURL: emptyUrl,
        imageThumbnailURL: emptyUrl,
        published: Date.init(),
        publisher: "",
        subtitle: "",
        summary: "",
        title: "",
        updated: Date.init(),
        annotationsURL: emptyUrl,
        analyticsURL: emptyUrl,
        alternateURL: emptyUrl,
        relatedWorksURL: emptyUrl,
        previewLink: fakeAcquisition,
        seriesURL: emptyUrl,
        revokeURL: emptyUrl,
        reportURL: emptyUrl,
        timeTrackingURL: emptyUrl,
        contributors: [:],
        bookDuration: nil
      )
            
      bookRegistryMock = TPPBookRegistryMock()
      bookRegistryMock.addBook(book: fakeBook, state: .DownloadSuccessful)
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
      bookRegistryMock?.registry.removeAll()
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

      // There are one duplicated bookmark and one extra (local) bookmark,
      // which means it has been delete from another device and should be removed locally
      bookmarkBusinessLogic.updateLocalBookmarks(serverBookmarks: serverBookmarks,
                                                 localBookmarks: bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier),
                                                 bookmarksFailedToUpload: [TPPReadiumBookmark]()) {
        XCTAssertEqual(self.bookRegistryMock.readiumBookmarks(forIdentifier: self.bookIdentifier).count, 1)
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
}
