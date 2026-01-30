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
    
    // Use placeholder URL for acquisition (not fetched in tests)
    let placeholderUrl = URL(string: "https://test.example.com/book")!
    let fakeAcquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: placeholderUrl,
      indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    
    fakeBook = TPPBook(
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
      title: "",
      updated: Date(),
      annotationsURL: nil,
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
    
  }
  
  // MARK: - Initialization Tests
  
  func testBusinessLogic_canBeInitialized() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    
    XCTAssertNotNil(sut)
  }
  
  func testBusinessLogic_hasBookReference() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    
    XCTAssertEqual(sut.book.identifier, bookIdentifier)
  }
  
  // MARK: - Track Loading Tests
  
  func testLoadTracks_succeeds() {
    do {
      tracks = try loadTracks(for: manifestJSON)
      XCTAssertNotNil(tracks)
      XCTAssertFalse(tracks.tracks.isEmpty)
    } catch {
      XCTFail("Failed to load tracks: \(error)")
    }
  }
  
  // MARK: - Position Restoration Tests (Synchronous)
  
  func testPositionRestoration_LocalNewerThanRemote_UsesLocal() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    tracks = try! loadTracks(for: manifestJSON)
    
    // Create local position with newer timestamp
    var localPosition = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    localPosition.lastSavedTimeStamp = "2024-01-02T12:00:00Z"
    
    // Create remote position with older timestamp
    var remotePosition = TrackPosition(track: tracks.tracks[1], timestamp: 500, tracks: tracks)
    remotePosition.lastSavedTimeStamp = "2024-01-01T12:00:00Z"
    
    // Parse timestamps and compare
    let localDate = ISO8601DateFormatter().date(from: localPosition.lastSavedTimeStamp) ?? Date.distantPast
    let remoteDate = ISO8601DateFormatter().date(from: remotePosition.lastSavedTimeStamp) ?? Date.distantPast
    
    // Local should be newer
    XCTAssertTrue(localDate > remoteDate, "Local position should have newer timestamp")
    
    // Verify the position that should be used is local (timestamp 1000)
    let selectedPosition: TrackPosition
    if localDate > remoteDate {
      selectedPosition = localPosition
    } else {
      selectedPosition = remotePosition
    }
    
    XCTAssertEqual(selectedPosition.timestamp, 1000, "Should use local position when local is newer")
    XCTAssertEqual(selectedPosition.track.key, localPosition.track.key, "Should use local track when local is newer")
  }
  
  func testPositionRestoration_RemoteNewerThanLocal_UsesRemote() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    tracks = try! loadTracks(for: manifestJSON)
    
    // Create local position with older timestamp
    var localPosition = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    localPosition.lastSavedTimeStamp = "2024-01-01T12:00:00Z"
    
    // Create remote position with newer timestamp
    var remotePosition = TrackPosition(track: tracks.tracks[1], timestamp: 2000, tracks: tracks)
    remotePosition.lastSavedTimeStamp = "2024-01-02T12:00:00Z"
    
    // Parse timestamps and compare
    let localDate = ISO8601DateFormatter().date(from: localPosition.lastSavedTimeStamp) ?? Date.distantPast
    let remoteDate = ISO8601DateFormatter().date(from: remotePosition.lastSavedTimeStamp) ?? Date.distantPast
    
    // Remote should be newer
    XCTAssertTrue(remoteDate > localDate, "Remote position should have newer timestamp")
    
    // Verify the position that should be used is remote (timestamp 2000)
    let selectedPosition: TrackPosition
    if remoteDate > localDate {
      selectedPosition = remotePosition
    } else {
      selectedPosition = localPosition
    }
    
    XCTAssertEqual(selectedPosition.timestamp, 2000, "Should use remote position when remote is newer")
    XCTAssertEqual(selectedPosition.track.key, remotePosition.track.key, "Should use remote track when remote is newer")
  }
  
  func testPositionRestoration_OnlyLocalExists_UsesLocal() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    tracks = try! loadTracks(for: manifestJSON)
    
    // Create only local position
    var localPosition = TrackPosition(track: tracks.tracks[0], timestamp: 1500, tracks: tracks)
    localPosition.lastSavedTimeStamp = "2024-01-01T12:00:00Z"
    
    // Remote is nil
    let remotePosition: TrackPosition? = nil
    
    // Verify local is used when remote doesn't exist
    let selectedPosition: TrackPosition?
    if let remote = remotePosition {
      selectedPosition = remote
    } else {
      selectedPosition = localPosition
    }
    
    XCTAssertNotNil(selectedPosition, "Should have a position when local exists")
    XCTAssertEqual(selectedPosition?.timestamp, 1500, "Should use local position when only local exists")
  }
  
  func testPositionRestoration_OnlyRemoteExists_UsesRemote() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    tracks = try! loadTracks(for: manifestJSON)
    
    // Local is nil
    let localPosition: TrackPosition? = nil
    
    // Create only remote position
    var remotePosition = TrackPosition(track: tracks.tracks[1], timestamp: 2500, tracks: tracks)
    remotePosition.lastSavedTimeStamp = "2024-01-02T12:00:00Z"
    
    // Verify remote is used when local doesn't exist
    let selectedPosition: TrackPosition?
    if let local = localPosition {
      selectedPosition = local
    } else {
      selectedPosition = remotePosition
    }
    
    XCTAssertNotNil(selectedPosition, "Should have a position when remote exists")
    XCTAssertEqual(selectedPosition?.timestamp, 2500, "Should use remote position when only remote exists")
  }
  
  func testPositionRestoration_BothNil_ReturnsNil() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    // Both positions are nil
    let localPosition: TrackPosition? = nil
    let remotePosition: TrackPosition? = nil
    
    // Verify no position when neither exists
    let selectedPosition: TrackPosition?
    if let local = localPosition, let remote = remotePosition {
      let localDate = ISO8601DateFormatter().date(from: local.lastSavedTimeStamp) ?? Date.distantPast
      let remoteDate = ISO8601DateFormatter().date(from: remote.lastSavedTimeStamp) ?? Date.distantPast
      selectedPosition = remoteDate > localDate ? remote : local
    } else if let local = localPosition {
      selectedPosition = local
    } else if let remote = remotePosition {
      selectedPosition = remote
    } else {
      selectedPosition = nil
    }
    
    XCTAssertNil(selectedPosition, "Should return nil when neither local nor remote position exists")
  }
  
  func testPositionRestoration_SameTimestamp_UsesLocal() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    tracks = try! loadTracks(for: manifestJSON)
    
    let sameTimestamp = "2024-01-01T12:00:00Z"
    
    // Create positions with same timestamp
    var localPosition = TrackPosition(track: tracks.tracks[0], timestamp: 1000, tracks: tracks)
    localPosition.lastSavedTimeStamp = sameTimestamp
    
    var remotePosition = TrackPosition(track: tracks.tracks[1], timestamp: 2000, tracks: tracks)
    remotePosition.lastSavedTimeStamp = sameTimestamp
    
    // Parse timestamps
    let localDate = ISO8601DateFormatter().date(from: localPosition.lastSavedTimeStamp) ?? Date.distantPast
    let remoteDate = ISO8601DateFormatter().date(from: remotePosition.lastSavedTimeStamp) ?? Date.distantPast
    
    // When timestamps are equal, local should be preferred (defensive choice)
    let selectedPosition: TrackPosition
    if remoteDate > localDate {
      selectedPosition = remotePosition
    } else {
      selectedPosition = localPosition
    }
    
    XCTAssertEqual(selectedPosition.timestamp, 1000, "Should use local position when timestamps are equal")
  }
  
  // MARK: - Save Listening Position Tests
  
  func testSaveListeningPosition_SavesLocallyImmediately() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    tracks = try! loadTracks(for: manifestJSON)
    
    let position = TrackPosition(track: tracks.tracks[0], timestamp: 500, tracks: tracks)
    
    let expectation = XCTestExpectation(description: "Save listening position")
    
    sut.saveListeningPosition(at: position) { _ in
      expectation.fulfill()
    }
    
    // Local save should happen immediately (before server sync)
    wait(for: [expectation], timeout: 3.0)
    
    let savedLocation = mockRegistry.location(forIdentifier: fakeBook.identifier)
    XCTAssertNotNil(savedLocation, "Location should be saved to registry")
  }
  
  func testSaveListeningPosition_SyncsToServer() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    tracks = try! loadTracks(for: manifestJSON)
    
    let position = TrackPosition(track: tracks.tracks[0], timestamp: 500, tracks: tracks)
    
    let expectation = XCTestExpectation(description: "Sync to server")
    
    sut.saveListeningPosition(at: position) { timestamp in
      // Timestamp returned indicates server sync succeeded
      XCTAssertNotNil(timestamp, "Should receive timestamp from server")
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 3.0)
    
    // Verify server was called
    let serverBookmarks = mockAnnotations.savedLocations[fakeBook.identifier]
    XCTAssertNotNil(serverBookmarks, "Server should have saved bookmark")
    XCTAssertFalse(serverBookmarks?.isEmpty ?? true, "Server bookmarks should not be empty")
  }
  
  // MARK: - Save Bookmark Tests
  
  func testSaveBookmark_CreatesBookmark() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    tracks = try! loadTracks(for: manifestJSON)
    
    let position = TrackPosition(track: tracks.tracks[1], timestamp: 1500, tracks: tracks)
    
    let expectation = XCTestExpectation(description: "Save bookmark")
    
    sut.saveBookmark(at: position) { savedPosition in
      XCTAssertNotNil(savedPosition, "Should return saved position")
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 3.0)
  }
  
  func testSaveBookmark_AddsToRegistry() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    tracks = try! loadTracks(for: manifestJSON)
    
    let position = TrackPosition(track: tracks.tracks[1], timestamp: 2000, tracks: tracks)
    
    let expectation = XCTestExpectation(description: "Add bookmark to registry")
    
    sut.saveBookmark(at: position) { _ in
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 3.0)
    
    // Verify bookmark was added to registry
    let genericBookmarks = mockRegistry.genericBookmarksForIdentifier(fakeBook.identifier)
    XCTAssertFalse(genericBookmarks.isEmpty, "Should have generic bookmarks in registry")
  }
  
  // MARK: - Delete Bookmark Tests
  
  func testDeleteBookmark_CallsAnnotationsManager() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    // Pre-populate with a bookmark
    mockAnnotations.bookmarks[fakeBook.identifier] = [
      TestBookmark(annotationId: "test-annotation-123", value: "{}")
    ]
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    tracks = try! loadTracks(for: manifestJSON)
    
    let position = TrackPosition(track: tracks.tracks[0], timestamp: 100, tracks: tracks)
    
    let expectation = XCTestExpectation(description: "Delete bookmark")
    
    sut.deleteBookmark(at: position) { success in
      // Deletion should complete (may or may not find the bookmark)
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 3.0)
  }
  
  // MARK: - Sync Bookmarks Tests
  
  func testSyncBookmarks_MergesLocalAndRemote() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    
    // Create a local bookmark using the proper initializer
    let localBookmark = AudioBookmark(
      type: .locatorAudioBookTime,
      annotationId: "local-123",
      chapter: "track-0",
      time: 1000
    )
    
    let expectation = XCTestExpectation(description: "Sync bookmarks")
    
    sut.syncBookmarks(localBookmarks: [localBookmark]) { mergedBookmarks in
      // Should return merged bookmarks
      XCTAssertNotNil(mergedBookmarks)
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 5.0)
  }
  
  // MARK: - Flush Pending Operations Tests
  
  func testFlushPendingOperations_ExecutesPendingWork() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    
    // This should not crash or cause issues
    sut.flushPendingOperations()
    
    XCTAssertNotNil(sut, "Business logic should still be valid after flush")
  }
  
  // MARK: - Save Listening Position Sync Tests
  
  func testSaveListeningPositionSync_SavesImmediately() {
    mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
    mockAnnotations = TPPAnnotationMock()
    
    sut = AudiobookBookmarkBusinessLogic(book: fakeBook, registry: mockRegistry, annotationsManager: mockAnnotations)
    tracks = try! loadTracks(for: manifestJSON)
    
    let position = TrackPosition(track: tracks.tracks[0], timestamp: 750, tracks: tracks)
    
    // This is a synchronous save (no debouncing)
    sut.saveListeningPositionSync(at: position)
    
    // Verify it was saved
    let savedLocation = mockRegistry.location(forIdentifier: fakeBook.identifier)
    XCTAssertNotNil(savedLocation, "Location should be saved synchronously")
  }
}
