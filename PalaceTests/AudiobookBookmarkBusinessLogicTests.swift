//
//  AudiobookBookmarkBusinessLogicTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 5/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

class AudiobookBookmarkBusinessLogicTests: XCTestCase {
  
  var sut: AudiobookBookmarkBusinessLogic!
  var mockAnnotations: TPPAnnotationMock!
  var mockRegistry: TPPBookRegistryMock!
  let bookIdentifier = "fakeEpub"
  var fakeBook: TPPBook!
  
  let testID = "TestID"
  
  func loadTracks(for manifestJSON: ManifestJSON) throws -> Tracks {
    let manifest = try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
    return Tracks(manifest: manifest, audiobookID: testID, token: nil)
  }
  
  let manifestJSON: ManifestJSON = .snowcrash
  
  var tracks: Tracks!
  
  override func setUp() {
    super.setUp()
    
    let emptyUrl = URL(fileURLWithPath: "")
    let fakeAcquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: emptyUrl,
      indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    
    fakeBook = TPPBook(
      acquisitions: [fakeAcquisition],
      authors: [TPPBookAuthor](),
      categoryStrings: [String](),
      distributor: "",
      identifier: bookIdentifier,
      imageURL: emptyUrl,
      imageThumbnailURL: emptyUrl,
      published: Date(),
      publisher: "",
      subtitle: "",
      summary: "",
      title: "",
      updated: Date(),
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
    
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(book: fakeBook, state: .DownloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    tracks = try! loadTracks(for: manifestJSON)
  }
  
  func testSaveListeningPosition() {
    let expectation = XCTestExpectation(description: "SaveListeningPosition")
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    
    let localTestBookmark = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    let expectedString = localTestBookmark.toAudioBookmark().toTPPBookLocation()!.locationString
    sut.saveListeningPosition(at: localTestBookmark) { result in
      expectation.fulfill()
      XCTAssertEqual(self.mockAnnotations.savedLocations[self.fakeBook.identifier]?.first?.value ?? "", expectedString)
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testSaveBookmark() {
    let expectation = XCTestExpectation(description: "SaveBookmark")
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    
    let position = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    XCTAssertTrue(position.lastSavedTimeStamp.isEmpty)

    sut.saveBookmark(at: position) { bookmark in
      expectation.fulfill()
      XCTAssertNotNil(bookmark)
      XCTAssertFalse(bookmark!.lastSavedTimeStamp.isEmpty)
      XCTAssertTrue(position == bookmark)
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testFetchBookmarksDuplicate_LocalAndRemote() {
    let expectation = XCTestExpectation(description: "FetchAllBookmarks")
    let localTestBookmark = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    let localTestBookmarkTwo = TrackPosition(track: tracks.tracks[1], timestamp: 111000, tracks: tracks)
    let registryTestBookmarks = [localTestBookmark, localTestBookmarkTwo]
    
    let testBookmark = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    let testBookmarkThree = TrackPosition(track: tracks.tracks[2], timestamp: 1000, tracks: tracks)
    let remoteTestBookmarks = [testBookmark, testBookmarkThree]
    let expectedBookmarks = [testBookmark, localTestBookmark, localTestBookmarkTwo, testBookmarkThree]
    
    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toAudioBookmark().toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toAudioBookmark().toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.fetchBookmarks(for: tracks, toc: []) { bookmarks in
      expectation.fulfill()
      XCTAssertEqual(bookmarks.count, expectedBookmarks.count)
      expectedBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(bookmarks.filter { $0 == expectedBookmark }.isEmpty)
      }
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testFetchBookmarks_localOnly() {
    let expectation = XCTestExpectation(description: "FetchLocalBookmarks")
    
    let localTestBookmark = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    let localTestBookmarkThree = TrackPosition(track: tracks.tracks[2], timestamp: 1000, tracks: tracks)
    let registryTestBookmarks = [localTestBookmark, localTestBookmarkThree]
    let remoteTestBookmarks: [TrackPosition] = []
    let expectedBookmarks = [localTestBookmark, localTestBookmarkThree]
    
    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toAudioBookmark().toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toAudioBookmark().toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.fetchBookmarks(for: tracks, toc: []) { bookmarks in
      expectation.fulfill()
      XCTAssertEqual(bookmarks.count, expectedBookmarks.count)
      expectedBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(bookmarks.filter { $0 == expectedBookmark }.isEmpty)
      }
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testFetchBookmarks_RemoteOnly() {
    let expectation = XCTestExpectation(description: "FetchRemoteBookmarks")
    
    let registryTestBookmarks: [TrackPosition] = []
    let testBookmark = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    let testBookmarkTwo = TrackPosition(track: tracks.tracks[1], timestamp: 111000, tracks: tracks)
    let remoteTestBookmarks: [TrackPosition] = [testBookmark, testBookmarkTwo]
    let expectedBookmarks = [testBookmark, testBookmarkTwo]
    
    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toAudioBookmark().toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toAudioBookmark().toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.fetchBookmarks(for: tracks, toc: []) { bookmarks in
      expectation.fulfill()
      XCTAssertEqual(bookmarks.count, expectedBookmarks.count)
      expectedBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(bookmarks.filter { $0 == expectedBookmark }.isEmpty)
      }
    }
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testBookmarkSync_RemoteToLocal() {
    let expectation = XCTestExpectation(description: "SyncRemoteBookmarks")
    
    let localTestBookmark = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    let registryTestBookmarks: [TrackPosition] = [localTestBookmark]
    let testBookmarkTwo = TrackPosition(track: tracks.tracks[1], timestamp: 111000, tracks: tracks)
    let testBookmarkThree = TrackPosition(track: tracks.tracks[2], timestamp: 1000, tracks: tracks)
    let remoteTestBookmarks: [TrackPosition] = [testBookmarkTwo, testBookmarkThree]
    let expectedLocalBookmarks = [localTestBookmark, testBookmarkTwo, testBookmarkThree]
    
    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toAudioBookmark().toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toAudioBookmark().toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.syncBookmarks(localBookmarks: registryTestBookmarks.compactMap { $0.toAudioBookmark() }) { _ in
      let localBookmarks = self.mockRegistry.genericBookmarksForIdentifier(self.fakeBook.identifier)
      
      XCTAssertEqual(localBookmarks.count, expectedLocalBookmarks.count)
      expectedLocalBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(localBookmarks.filter { $0.locationString == expectedBookmark.toAudioBookmark().toTPPBookLocation()?.locationString }.isEmpty)
      }
    }
    
    expectation.fulfill()
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testBookmarkSync_LocalToRemote() {
    let expectation = XCTestExpectation(description: "SyncLocalBookmarks")
    
    let localTestBookmark = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    let localTestBookmarkTwo = TrackPosition(track: tracks.tracks[1], timestamp: 111000, tracks: tracks)
    let localTestBookmarkThree = TrackPosition(track: tracks.tracks[2], timestamp: 1000, tracks: tracks)
    let registryTestBookmarks: [TrackPosition] = [localTestBookmark, localTestBookmarkTwo, localTestBookmarkThree]
    let remoteTestBookmarks: [TrackPosition] = []
    
    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toAudioBookmark().toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toAudioBookmark().toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.syncBookmarks(localBookmarks: registryTestBookmarks.compactMap { $0.toAudioBookmark() }) { _ in
      
      let remoteBookmarks = self.mockAnnotations.bookmarks[self.fakeBook.identifier]?.compactMap { $0.value } ?? []
      XCTAssertEqual(remoteBookmarks.count, registryTestBookmarks.count)
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testDeleteBookmark_localOnly() {
    let expectation = XCTestExpectation(description: "DeleteLocalBookmarks")
    
    let localTestBookmark = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    let localTestBookmarkTwo = TrackPosition(track: tracks.tracks[1], timestamp: 111000, tracks: tracks)
    let localTestBookmarkThree = TrackPosition(track: tracks.tracks[2], timestamp: 1000, tracks: tracks)
    let deletedBookmark = localTestBookmarkTwo
    let registryTestBookmarks: [TrackPosition] = [localTestBookmark, deletedBookmark, localTestBookmarkThree]
    let remoteTestBookmarks: [TrackPosition] = []
    let expectedLocalBookmarks = [localTestBookmark, localTestBookmarkThree]
    
    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toAudioBookmark().toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toAudioBookmark().toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.deleteBookmark(at: deletedBookmark) { success in
      XCTAssertTrue(success)
      let localBookmarks = self.mockRegistry.genericBookmarksForIdentifier(self.fakeBook.identifier)
      
      XCTAssertEqual(localBookmarks.count, expectedLocalBookmarks.count)
      expectedLocalBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(localBookmarks.filter { $0.locationString == expectedBookmark.toAudioBookmark().toTPPBookLocation()?.locationString }.isEmpty)
      }
      
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 5.0)
  }
  
  func testDeleteBookmark_localAndRemote() {
    let expectation = XCTestExpectation(description: "DeleteLocalAndRemoteBookmarks")
    
    let testBookmark = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    let testBookmarkTwo = TrackPosition(track: tracks.tracks[1], timestamp: 111000, tracks: tracks)
    let localTestBookmarkThree = TrackPosition(track: tracks.tracks[2], timestamp: 1000, tracks: tracks)
    let registryTestBookmarks: [TrackPosition] = [testBookmark, testBookmarkTwo, localTestBookmarkThree]
    let remoteTestBookmarks: [TrackPosition] = [testBookmark, testBookmarkTwo]
    let expectedLocalBookmarks = [testBookmark, localTestBookmarkThree]
    let expectedRemoteBookmarks = [testBookmark]
    
    mockRegistry.preloadData(bookIdentifier: fakeBook.identifier, locations: registryTestBookmarks.compactMap { $0.toAudioBookmark().toTPPBookLocation() })
    let remoteBookmarks = remoteTestBookmarks.compactMap { TestBookmark(annotationId: $0.annotationId, value: $0.toAudioBookmark().toTPPBookLocation()!.locationString) }
    mockAnnotations.bookmarks = [fakeBook.identifier: remoteBookmarks]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    sut.deleteBookmark(at: testBookmarkTwo) { success in
      XCTAssertTrue(success)
      let localBookmarks = self.mockRegistry.genericBookmarksForIdentifier(self.fakeBook.identifier)
      
      XCTAssertEqual(localBookmarks.count, expectedLocalBookmarks.count)
      expectedLocalBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(localBookmarks.filter { $0.locationString == expectedBookmark.toAudioBookmark().toTPPBookLocation()?.locationString }.isEmpty)
      }
      
      let remoteBookmarks = self.mockAnnotations.bookmarks[self.fakeBook.identifier]?.compactMap { $0.value } ?? []
      XCTAssertEqual(remoteBookmarks.count, expectedRemoteBookmarks.count)
      
      expectedRemoteBookmarks.forEach { expectedBookmark in
        XCTAssertFalse(remoteBookmarks.filter { $0.contains(expectedBookmark.annotationId) }.isEmpty)
      }
      
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 5.0)
  }
}
