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
  
  let testLocation = ChapterLocation(
    number: 0,
    part: 0,
    duration: TimeInterval(floatLiteral: 44000),
    startOffset: TimeInterval(floatLiteral: 1000),
    playheadOffset:TimeInterval(floatLiteral: 1000),
    title: "Test Title",
    audiobookID: "123456789123456"
  )
  
  let testLocationTwo = ChapterLocation(
    number: 0,
    part: 0,
    duration: TimeInterval(floatLiteral: 66000),
    startOffset: TimeInterval(floatLiteral: 1000),
    playheadOffset:TimeInterval(floatLiteral: 111000),
    title: "Test Title",
    audiobookID: "123456789123456"
  )
  
  let testLocationThree = ChapterLocation(
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

    let expectedString = testLocation.toTPPBookLocation()!.locationString
    sut.saveListeningPosition(at: expectedString) { result in
      expectation.fulfill()
      XCTAssertEqual(self.mockAnnotations.savedLocations[self.fakeBook.identifier]?.first?.value ?? "", expectedString)
    }
    wait(for: [expectation], timeout: 5.0)
  }

  func testSaveBookmark() {
    let expectation = XCTestExpectation(description: "SaveBookmark")
    XCTAssertTrue(testLocation.lastSavedTimeStamp.isEmpty)
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)

    sut.saveBookmark(at: testLocation) { location in
      expectation.fulfill()
      XCTAssertNotNil(location)
      XCTAssertFalse(location!.lastSavedTimeStamp.isEmpty)
      XCTAssertTrue(self.testLocation.isSimilar(to: location!))
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testFetchBookmarksDuplicate_LocalAndRemote() {
    let expectation = XCTestExpectation(description: "FetchAllBookmarks")
    let registryTestLocations = [testLocation, testLocationTwo]
    let remoteTestLocations = [testLocation, testLocationThree]
    let expectedLocations = [testLocation, testLocationTwo, testLocationThree]

    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestLocations.compactMap { $0.toTPPBookLocation() })
    let remoteBookmarks =  remoteTestLocations.compactMap { TestBookmark(annotationId: "TestAnnotationId\(fakeBook.identifier)", value: $0.toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.fetchBookmarks{ locations in
      expectation.fulfill()
      XCTAssertEqual(locations.count, expectedLocations.count)
      expectedLocations.forEach { expectedBookmark in
        XCTAssertFalse(locations.filter { $0.isSimilar(to: expectedBookmark) }.isEmpty)
      }
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testFetchBookmarks_localOnly() {
    let expectation = XCTestExpectation(description: "FetchLocalBookmarks")

    let registryTestLocations = [testLocation, testLocationTwo]
    let remoteTestLocations: [ChapterLocation] = []
    let expectedLocations = [testLocation, testLocationTwo]

    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestLocations.compactMap { $0.toTPPBookLocation() })
    let remoteBookmarks = remoteTestLocations.compactMap { TestBookmark(annotationId: "TestAnnotationId\(fakeBook.identifier)", value: $0.toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.fetchBookmarks{ locations in
      expectation.fulfill()
      XCTAssertEqual(locations.count, expectedLocations.count)
      expectedLocations.forEach { expectedBookmark in
        XCTAssertFalse(locations.filter { $0.isSimilar(to: expectedBookmark) }.isEmpty)
      }
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testFetchBookmarks_RemoteOnly() {
    let expectation = XCTestExpectation(description: "FetchRemoteBookmarks")

    let registryTestLocations: [ChapterLocation] = []
    let remoteTestLocations: [ChapterLocation] = [testLocation, testLocationTwo]
    let expectedLocations = [testLocation, testLocationTwo]

    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestLocations.compactMap { $0.toTPPBookLocation() })
    let remoteBookmarks = remoteTestLocations.compactMap { TestBookmark(annotationId: "TestAnnotationId\(fakeBook.identifier)", value: $0.toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.fetchBookmarks{ locations in
      expectation.fulfill()
      XCTAssertEqual(locations.count, expectedLocations.count)
      expectedLocations.forEach { expectedBookmark in
        XCTAssertFalse(locations.filter { $0.isSimilar(to: expectedBookmark) }.isEmpty)
      }
    }
    wait(for: [expectation], timeout: 5.0)
  }
}
