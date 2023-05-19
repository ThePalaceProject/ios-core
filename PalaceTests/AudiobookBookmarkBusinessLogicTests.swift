//
//  AudiobookBookmarkBusinessLogicTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 5/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

class AudiobookBookmarkBusinessLogicTests: XCTestCase {

  var sut: AudiobookBookmarkBusinessLogic!
  var mockAnnotations: TPPAnnotationMock!
  var mockRegistry: TPPBookRegistryMock!
  let bookIdentifier = "fakeEpub"
  var fakeBook: TPPBook!
  
  let testBookmark = ChapterLocation(
    number: 0,
    part: 0,
    duration: TimeInterval(floatLiteral: 44000),
    startOffset: TimeInterval(floatLiteral: 1000),
    playheadOffset:TimeInterval(floatLiteral: 1000),
    title: "Test Title",
    audiobookID: "123456789123456",
    annotationId: "TestAnnotationId\(UUID().uuidString)"
  )
  
  let testBookmarkTwo = ChapterLocation(
    number: 0,
    part: 0,
    duration: TimeInterval(floatLiteral: 66000),
    startOffset: TimeInterval(floatLiteral: 1000),
    playheadOffset:TimeInterval(floatLiteral: 111000),
    title: "Test Title",
    audiobookID: "123456789123456",
    annotationId: "TestAnnotationId\(UUID().uuidString)"
  )
  
  let testBookmarkThree = ChapterLocation(
    number: 0,
    part: 0,
    duration: TimeInterval(floatLiteral: 5500),
    startOffset: TimeInterval(floatLiteral: 1000),
    playheadOffset:TimeInterval(floatLiteral: 1000),
    title: "Test Title",
    audiobookID: "123456789123456",
    annotationId: "TestAnnotationId\(UUID().uuidString)"
  )

  let localTestBookmark = ChapterLocation(
    number: 0,
    part: 0,
    duration: TimeInterval(floatLiteral: 44000),
    startOffset: TimeInterval(floatLiteral: 1000),
    playheadOffset:TimeInterval(floatLiteral: 1000),
    title: "Test Title",
    audiobookID: "123456789123456"
  )
  
  let localTestBookmarkTwo = ChapterLocation(
    number: 0,
    part: 0,
    duration: TimeInterval(floatLiteral: 66000),
    startOffset: TimeInterval(floatLiteral: 1000),
    playheadOffset:TimeInterval(floatLiteral: 111000),
    title: "Test Title",
    audiobookID: "123456789123456"
  )
  
  let localTestBookmarkThree = ChapterLocation(
    number: 0,
    part: 0,
    duration: TimeInterval(floatLiteral: 5500),
    startOffset: TimeInterval(floatLiteral: 1000),
    playheadOffset:TimeInterval(floatLiteral: 1000),
    title: "Test Title",
    audiobookID: "123456789123456"
  )
  
  override func setUp() {
    super.setUp()

    let emptyUrl = URL.init(fileURLWithPath: "")
    let fakeAcquisition = TPPOPDSAcquisition.init(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: emptyUrl,
      indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
      availability: TPPOPDSAcquisitionAvailabilityUnlimited.init()
    )

    fakeBook = TPPBook.init(
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
      contributors: [:]
    )

    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(book: fakeBook, state: .DownloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
  }
  
  func testSaveListeningPosition() {
    let expectation = XCTestExpectation(description: "SaveListeningPosition")
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)

    let expectedString = localTestBookmark.toTPPBookLocation()!.locationString
    sut.saveListeningPosition(at: expectedString) { result in
      expectation.fulfill()
      XCTAssertEqual(self.mockAnnotations.savedLocations[self.fakeBook.identifier]?.first?.value ?? "", expectedString)
    }
    wait(for: [expectation], timeout: 5.0)
  }

  func testSaveBookmark() {
    let expectation = XCTestExpectation(description: "SaveBookmark")
    XCTAssertTrue(testBookmark.lastSavedTimeStamp.isEmpty)
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)

    sut.saveBookmark(at: testBookmark) { Bookmark in
      expectation.fulfill()
      XCTAssertNotNil(Bookmark)
      XCTAssertFalse(Bookmark!.lastSavedTimeStamp.isEmpty)
      XCTAssertTrue(self.testBookmark.isSimilar(to: Bookmark!))
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testFetchBookmarksDuplicate_LocalAndRemote() {
    let expectation = XCTestExpectation(description: "FetchAllBookmarks")
    let registryTestBookmarks = [localTestBookmark, localTestBookmarkTwo]
    let remoteTestBookmarks = [testBookmark, testBookmarkThree]
    let expectedBookmarks = [testBookmark, testBookmarkTwo, testBookmarkThree]

    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.fetchBookmarks{ Bookmarks in
      expectation.fulfill()
      XCTAssertEqual(Bookmarks.count, expectedBookmarks.count)
      expectedBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(Bookmarks.filter { $0.isSimilar(to: expectedBookmark) }.isEmpty)
      }
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testFetchBookmarks_localOnly() {
    let expectation = XCTestExpectation(description: "FetchLocalBookmarks")

    let registryTestBookmarks = [localTestBookmark, localTestBookmarkThree]
    let remoteTestBookmarks: [ChapterLocation] = []
    let expectedBookmarks = [localTestBookmark, localTestBookmarkThree]

    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.fetchBookmarks{ Bookmarks in
      expectation.fulfill()
      XCTAssertEqual(Bookmarks.count, expectedBookmarks.count)
      expectedBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(Bookmarks.filter { $0.isSimilar(to: expectedBookmark) }.isEmpty)
      }
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testFetchBookmarks_RemoteOnly() {
    let expectation = XCTestExpectation(description: "FetchRemoteBookmarks")

    let registryTestBookmarks: [ChapterLocation] = []
    let remoteTestBookmarks: [ChapterLocation] = [testBookmark, testBookmarkTwo]
    let expectedBookmarks = [testBookmark, testBookmarkTwo]

    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.fetchBookmarks{ Bookmarks in
      expectation.fulfill()
      XCTAssertEqual(Bookmarks.count, expectedBookmarks.count)
      expectedBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(Bookmarks.filter { $0.isSimilar(to: expectedBookmark) }.isEmpty)
      }
    }
    wait(for: [expectation], timeout: 5.0)
  }

  func testBookmarkSync_RemoteToLocal() {
    let expectation = XCTestExpectation(description: "SyncRemoteBookmarks")

    let registryTestBookmarks: [ChapterLocation] = [localTestBookmark]
    let remoteTestBookmarks: [ChapterLocation] = [testBookmarkTwo, testBookmarkThree]
    let expectedLocalBookmarks = [testBookmark, testBookmarkTwo, testBookmarkThree]

    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]

    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.syncBookmarks(localBookmarks: registryTestBookmarks) {
      let localBookmarks = self.mockRegistry.genericBookmarksForIdentifier(self.fakeBook.identifier)
      
      XCTAssertEqual(localBookmarks.count, expectedLocalBookmarks.count)
      expectedLocalBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(localBookmarks.filter { $0.locationString == expectedBookmark.toTPPBookLocation()?.locationString }.isEmpty)
      }
    }

    expectation.fulfill()
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testBookmarkSync_LocalToRemote() {
    let expectation = XCTestExpectation(description: "SyncLocalBookmarks")

    let registryTestBookmarks: [ChapterLocation] = [localTestBookmark, localTestBookmarkTwo, localTestBookmarkThree]
    let remoteTestBookmarks: [ChapterLocation] = []
    let expectedRemoteBookmarks = [localTestBookmark, localTestBookmarkTwo, localTestBookmarkThree]

    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]

    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.syncBookmarks(localBookmarks: registryTestBookmarks) {
      
      let remoteBookmarks = self.mockAnnotations.bookmarks[self.fakeBook.identifier]?.compactMap { $0.value } ?? []
      expectedRemoteBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(remoteBookmarks.filter { $0 == expectedBookmark.toTPPBookLocation()?.locationString }.isEmpty)
      }

      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 105.0)
  }
  
  func testDeleteBookmark_localOnly() {
    let expectation = XCTestExpectation(description: "DeleteLocalBookmarks")

    let registryTestBookmarks: [ChapterLocation] = [localTestBookmark, localTestBookmarkTwo, localTestBookmarkThree]
    let remoteTestBookmarks: [ChapterLocation] = []
    let expectedLocalBookmarks = [localTestBookmark, localTestBookmarkThree]

    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]

    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.deleteBookmark(at: localTestBookmarkTwo) { success in
      XCTAssertTrue(success)
      let localBookmarks = self.mockRegistry.genericBookmarksForIdentifier(self.fakeBook.identifier)

      XCTAssertEqual(localBookmarks.count, expectedLocalBookmarks.count)
      expectedLocalBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(localBookmarks.filter { $0.locationString == expectedBookmark.toTPPBookLocation()?.locationString }.isEmpty)
      }

      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 5.0)
  }
  
  func testDeleteBookmark_localAndRemote() {
    let expectation = XCTestExpectation(description: "DeleteLocalAndRemoteBookmarks")

    let registryTestBookmarks: [ChapterLocation] = [testBookmark, testBookmarkTwo, localTestBookmarkThree]
    let remoteTestBookmarks: [ChapterLocation] = [testBookmark, testBookmarkTwo]
    let expectedLocalBookmarks = [testBookmark, localTestBookmarkThree]
    let expectedRemoteBookmarks = [testBookmark]

    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]

    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.deleteBookmark(at: testBookmarkTwo) { success in
      XCTAssertTrue(success)
      let localBookmarks = self.mockRegistry.genericBookmarksForIdentifier(self.fakeBook.identifier)

      XCTAssertEqual(localBookmarks.count, expectedLocalBookmarks.count)
      expectedLocalBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(localBookmarks.filter { $0.locationString == expectedBookmark.toTPPBookLocation()?.locationString }.isEmpty)
      }
      
      let remoteBookmarks = self.mockAnnotations.bookmarks[self.fakeBook.identifier]?.compactMap { $0.value } ?? []
      XCTAssertEqual(remoteBookmarks.count, expectedRemoteBookmarks.count)

      expectedRemoteBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(remoteBookmarks.filter { $0 == expectedBookmark.toTPPBookLocation()?.locationString }.isEmpty)
      }

      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 5.0)
  }
}
