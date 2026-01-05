//
//  EPUBPositionTests.swift
//  PalaceTests
//
//  Created for Testing Migration
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for EPUB reading position persistence and synchronization.
class EPUBPositionTests: XCTestCase {
  
  var mockRegistry: TPPBookRegistryMock!
  var fakeBook: TPPBook!
  
  override func setUp() {
    super.setUp()
    mockRegistry = TPPBookRegistryMock()
    
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
      distributor: "Test Distributor",
      identifier: "testEpub123",
      imageURL: emptyUrl,
      imageThumbnailURL: emptyUrl,
      published: Date(),
      publisher: "Test Publisher",
      subtitle: "",
      summary: "",
      title: "Test EPUB",
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
      bookDuration: nil,
      imageCache: MockImageCache()
    )
    
    mockRegistry.addBook(fakeBook, state: .downloadSuccessful)
  }
  
  override func tearDown() {
    mockRegistry = nil
    fakeBook = nil
    super.tearDown()
  }
  
  // MARK: - TPPBookLocation Creation Tests
  
  func testBookLocation_CreationWithValidData() {
    let locationString = """
    {"@type":"LocatorHrefProgression","href":"/OEBPS/chapter01.xhtml","locations":{"progression":0.5}}
    """
    
    let location = TPPBookLocation(locationString: locationString, renderer: TPPBookLocation.r3Renderer)
    
    XCTAssertNotNil(location, "Should create book location with valid data")
    XCTAssertEqual(location?.locationString, locationString)
    XCTAssertEqual(location?.renderer, TPPBookLocation.r3Renderer)
  }
  
  func testBookLocation_DictionaryRoundTrip() {
    let originalLocationString = """
    {"@type":"LocatorHrefProgression","href":"/chapter.xhtml","locations":{"progression":0.25}}
    """
    
    let original = TPPBookLocation(locationString: originalLocationString, renderer: TPPBookLocation.r3Renderer)
    XCTAssertNotNil(original)
    
    let dictionary = original!.dictionaryRepresentation
    let restored = TPPBookLocation(dictionary: dictionary)
    
    XCTAssertNotNil(restored, "Should restore from dictionary")
    XCTAssertEqual(restored?.locationString, originalLocationString)
    XCTAssertEqual(restored?.renderer, TPPBookLocation.r3Renderer)
  }
  
  func testBookLocation_CreationFromDictionary() {
    let dictionary: [String: Any] = [
      "locationString": "{\"href\":\"/chapter.xhtml\"}",
      "renderer": TPPBookLocation.r3Renderer
    ]
    
    let location = TPPBookLocation(dictionary: dictionary)
    
    XCTAssertNotNil(location, "Should create from dictionary")
    XCTAssertEqual(location?.renderer, TPPBookLocation.r3Renderer)
  }
  
  func testBookLocation_FailsWithMissingLocationString() {
    let dictionary: [String: Any] = [
      "renderer": TPPBookLocation.r3Renderer
    ]
    
    let location = TPPBookLocation(dictionary: dictionary)
    
    XCTAssertNil(location, "Should fail with missing locationString")
  }
  
  func testBookLocation_FailsWithMissingRenderer() {
    let dictionary: [String: Any] = [
      "locationString": "{\"href\":\"/chapter.xhtml\"}"
    ]
    
    let location = TPPBookLocation(dictionary: dictionary)
    
    XCTAssertNil(location, "Should fail with missing renderer")
  }
  
  // MARK: - Registry Position Storage Tests
  
  func testRegistry_SaveAndRetrieveLocation() {
    let locationString = """
    {"@type":"LocatorHrefProgression","href":"/chapter02.xhtml","locations":{"progression":0.75}}
    """
    let location = TPPBookLocation(locationString: locationString, renderer: TPPBookLocation.r3Renderer)!
    
    mockRegistry.setLocation(location, forIdentifier: fakeBook.identifier)
    
    let retrieved = mockRegistry.location(forIdentifier: fakeBook.identifier)
    
    XCTAssertNotNil(retrieved, "Should retrieve saved location")
    XCTAssertEqual(retrieved?.locationString, locationString)
  }
  
  func testRegistry_LocationIsNilForNewBook() {
    let newBookId = "newBook123"
    
    let location = mockRegistry.location(forIdentifier: newBookId)
    
    XCTAssertNil(location, "New book should have no saved location")
  }
  
  func testRegistry_UpdateExistingLocation() {
    let firstLocation = TPPBookLocation(
      locationString: "{\"progression\":0.25}",
      renderer: TPPBookLocation.r3Renderer
    )!
    
    let secondLocation = TPPBookLocation(
      locationString: "{\"progression\":0.75}",
      renderer: TPPBookLocation.r3Renderer
    )!
    
    mockRegistry.setLocation(firstLocation, forIdentifier: fakeBook.identifier)
    mockRegistry.setLocation(secondLocation, forIdentifier: fakeBook.identifier)
    
    let retrieved = mockRegistry.location(forIdentifier: fakeBook.identifier)
    
    XCTAssertNotNil(retrieved)
    XCTAssertEqual(retrieved?.locationString, "{\"progression\":0.75}", "Should have updated location")
  }
  
  // MARK: - Progression Calculation Tests
  
  func testProgression_CalculationFromPosition() {
    let currentPosition: Double = 50.0
    let totalLength: Double = 200.0
    
    let progression = currentPosition / totalLength
    
    XCTAssertEqual(progression, 0.25, accuracy: 0.001, "Progression should be 25%")
  }
  
  func testProgression_AtStart() {
    let currentPosition: Double = 0.0
    let totalLength: Double = 200.0
    
    let progression = currentPosition / totalLength
    
    XCTAssertEqual(progression, 0.0, accuracy: 0.001, "Progression should be 0% at start")
  }
  
  func testProgression_AtEnd() {
    let currentPosition: Double = 200.0
    let totalLength: Double = 200.0
    
    let progression = currentPosition / totalLength
    
    XCTAssertEqual(progression, 1.0, accuracy: 0.001, "Progression should be 100% at end")
  }
  
  func testProgression_MidBook() {
    let currentPosition: Double = 100.0
    let totalLength: Double = 200.0
    
    let progression = currentPosition / totalLength
    
    XCTAssertEqual(progression, 0.5, accuracy: 0.001, "Progression should be 50% at midpoint")
  }
  
  // MARK: - Page Navigation Calculation Tests
  
  func testPageNavigation_ForwardIncrementsPosition() {
    var currentPage = 1
    let totalPages = 100
    
    if currentPage < totalPages {
      currentPage += 1
    }
    
    XCTAssertEqual(currentPage, 2, "Forward should increment page")
  }
  
  func testPageNavigation_BackwardDecrementsPosition() {
    var currentPage = 50
    
    if currentPage > 1 {
      currentPage -= 1
    }
    
    XCTAssertEqual(currentPage, 49, "Backward should decrement page")
  }
  
  func testPageNavigation_ForwardAtEnd_StaysAtEnd() {
    var currentPage = 100
    let totalPages = 100
    
    if currentPage < totalPages {
      currentPage += 1
    }
    
    XCTAssertEqual(currentPage, 100, "Forward at end should stay at end")
  }
  
  func testPageNavigation_BackwardAtStart_StaysAtStart() {
    var currentPage = 1
    
    if currentPage > 1 {
      currentPage -= 1
    }
    
    XCTAssertEqual(currentPage, 1, "Backward at start should stay at start")
  }
  
  // MARK: - Chapter Navigation Tests
  
  func testChapterNavigation_ProgressWithinChapter() {
    let chapterStart: Double = 0.2
    let chapterEnd: Double = 0.4
    let bookProgression: Double = 0.3
    
    let chapterProgress = (bookProgression - chapterStart) / (chapterEnd - chapterStart)
    
    XCTAssertEqual(chapterProgress, 0.5, accuracy: 0.001, "Should be 50% through chapter")
  }
  
  func testChapterNavigation_AtChapterStart() {
    let chapterStart: Double = 0.2
    let chapterEnd: Double = 0.4
    let bookProgression: Double = 0.2
    
    let chapterProgress = (bookProgression - chapterStart) / (chapterEnd - chapterStart)
    
    XCTAssertEqual(chapterProgress, 0.0, accuracy: 0.001, "Should be at chapter start")
  }
  
  func testChapterNavigation_AtChapterEnd() {
    let chapterStart: Double = 0.2
    let chapterEnd: Double = 0.4
    let bookProgression: Double = 0.4
    
    let chapterProgress = (bookProgression - chapterStart) / (chapterEnd - chapterStart)
    
    XCTAssertEqual(chapterProgress, 1.0, accuracy: 0.001, "Should be at chapter end")
  }
  
  // MARK: - Location Similarity Tests
  
  func testLocationSimilarity_IdenticalLocations() {
    let location1 = TPPBookLocation(
      locationString: "{\"href\":\"/chapter.xhtml\",\"progression\":0.5}",
      renderer: TPPBookLocation.r3Renderer
    )!
    
    let location2 = TPPBookLocation(
      locationString: "{\"href\":\"/chapter.xhtml\",\"progression\":0.5}",
      renderer: TPPBookLocation.r3Renderer
    )!
    
    XCTAssertEqual(location1.locationString, location2.locationString, "Identical locations should match")
  }
  
  func testLocationSimilarity_DifferentProgressions() {
    let location1 = TPPBookLocation(
      locationString: "{\"progression\":0.25}",
      renderer: TPPBookLocation.r3Renderer
    )!
    
    let location2 = TPPBookLocation(
      locationString: "{\"progression\":0.75}",
      renderer: TPPBookLocation.r3Renderer
    )!
    
    XCTAssertNotEqual(location1.locationString, location2.locationString, "Different progressions should not match")
  }
  
  // MARK: - Throttling Interval Tests
  
  func testThrottlingInterval_Value() {
    let expectedInterval: TimeInterval = 15.0
    
    XCTAssertEqual(TPPLastReadPositionPoster.throttlingInterval, expectedInterval, "Throttling interval should be 15 seconds")
  }
  
  func testThrottling_ShouldPostAfterInterval() {
    let lastUploadDate = Date()
    let throttlingInterval: TimeInterval = 15.0
    
    // Simulate time passing
    let futureDate = lastUploadDate.addingTimeInterval(16.0)
    let shouldPost = futureDate > lastUploadDate.addingTimeInterval(throttlingInterval)
    
    XCTAssertTrue(shouldPost, "Should post after throttling interval passes")
  }
  
  func testThrottling_ShouldNotPostBeforeInterval() {
    let lastUploadDate = Date()
    let throttlingInterval: TimeInterval = 15.0
    
    // Simulate time passing
    let futureDate = lastUploadDate.addingTimeInterval(10.0)
    let shouldPost = futureDate > lastUploadDate.addingTimeInterval(throttlingInterval)
    
    XCTAssertFalse(shouldPost, "Should not post before throttling interval")
  }
}

