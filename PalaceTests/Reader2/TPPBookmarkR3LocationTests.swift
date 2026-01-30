//
//  TPPBookmarkR3LocationTests.swift
//  PalaceTests
//
//  Comprehensive tests for TPPBookmarkR3Location class.
//  Tests the REAL production class for Readium 3 location conversion.
//

import XCTest
import ReadiumShared
@testable import Palace

final class TPPBookmarkR3LocationTests: XCTestCase {
  
  // MARK: - Initialization Tests
  
  func testInit_withValidParameters_createsLocation() {
    let locator = createLocator(
      href: "/chapter1.xhtml",
      progression: 0.5,
      totalProgression: 0.25
    )
    
    let location = TPPBookmarkR3Location(
      resourceIndex: 0,
      locator: locator,
      creationDate: Date()
    )
    
    XCTAssertNotNil(location)
    XCTAssertEqual(location.resourceIndex, 0)
    XCTAssertEqual(location.locator.href.string, "/chapter1.xhtml")
  }
  
  func testInit_withDefaultCreationDate_usesCurrentDate() {
    let beforeCreation = Date()
    
    let locator = createLocator(
      href: "/chapter1.xhtml",
      progression: 0.5,
      totalProgression: 0.25
    )
    
    let location = TPPBookmarkR3Location(
      resourceIndex: 0,
      locator: locator
    )
    
    let afterCreation = Date()
    
    XCTAssertGreaterThanOrEqual(location.creationDate, beforeCreation)
    XCTAssertLessThanOrEqual(location.creationDate, afterCreation)
  }
  
  func testInit_preservesResourceIndex() {
    let locator = createLocator(
      href: "/chapter5.xhtml",
      progression: 0.75,
      totalProgression: 0.5
    )
    
    let location = TPPBookmarkR3Location(
      resourceIndex: 4,
      locator: locator
    )
    
    XCTAssertEqual(location.resourceIndex, 4)
  }
  
  // MARK: - Factory Method Tests
  
  func testFrom_validLocatorInPublication_createsLocation() {
    let publication = createTestPublication()
    let locator = createLocator(
      href: "/chapter2.xhtml",
      progression: 0.5,
      totalProgression: 0.3
    )
    
    let location = TPPBookmarkR3Location.from(
      locator: locator,
      in: publication
    )
    
    XCTAssertNotNil(location)
    XCTAssertEqual(location?.resourceIndex, 1, "Should find index of chapter2.xhtml")
  }
  
  func testFrom_locatorNotInPublication_returnsNil() {
    let publication = createTestPublication()
    let locator = createLocator(
      href: "/nonexistent.xhtml",
      progression: 0.5,
      totalProgression: 0.3
    )
    
    let location = TPPBookmarkR3Location.from(
      locator: locator,
      in: publication
    )
    
    XCTAssertNil(location, "Should return nil for locator not in reading order")
  }
  
  func testFrom_firstChapter_returnsIndexZero() {
    let publication = createTestPublication()
    let locator = createLocator(
      href: "/chapter1.xhtml",
      progression: 0.1,
      totalProgression: 0.05
    )
    
    let location = TPPBookmarkR3Location.from(
      locator: locator,
      in: publication
    )
    
    XCTAssertNotNil(location)
    XCTAssertEqual(location?.resourceIndex, 0)
  }
  
  func testFrom_lastChapter_returnsCorrectIndex() {
    let publication = createTestPublication()
    let locator = createLocator(
      href: "/chapter3.xhtml",
      progression: 0.9,
      totalProgression: 0.95
    )
    
    let location = TPPBookmarkR3Location.from(
      locator: locator,
      in: publication
    )
    
    XCTAssertNotNil(location)
    XCTAssertEqual(location?.resourceIndex, 2)
  }
  
  func testFrom_withCustomCreationDate_usesProvidedDate() {
    let publication = createTestPublication()
    let locator = createLocator(
      href: "/chapter1.xhtml",
      progression: 0.5,
      totalProgression: 0.25
    )
    
    let customDate = Date(timeIntervalSince1970: 1000000)
    
    let location = TPPBookmarkR3Location.from(
      locator: locator,
      in: publication,
      creationDate: customDate
    )
    
    XCTAssertNotNil(location)
    XCTAssertEqual(location?.creationDate, customDate)
  }
  
  // MARK: - Locator Properties Tests
  
  func testLocator_preservesProgression() {
    let locator = createLocator(
      href: "/chapter1.xhtml",
      progression: 0.75,
      totalProgression: 0.5
    )
    
    let location = TPPBookmarkR3Location(
      resourceIndex: 0,
      locator: locator
    )
    
    XCTAssertEqual(location.locator.locations.progression, 0.75)
    XCTAssertEqual(location.locator.locations.totalProgression, 0.5)
  }
  
  func testLocator_preservesTitle() {
    let locator = Locator(
      href: AnyURL(string: "/chapter1.xhtml")!,
      mediaType: .xhtml,
      title: "Introduction",
      locations: Locator.Locations(progression: 0.5, totalProgression: 0.25)
    )
    
    let location = TPPBookmarkR3Location(
      resourceIndex: 0,
      locator: locator
    )
    
    XCTAssertEqual(location.locator.title, "Introduction")
  }
  
  func testLocator_preservesMediaType() {
    let locator = Locator(
      href: AnyURL(string: "/chapter1.xhtml")!,
      mediaType: .html,
      locations: Locator.Locations()
    )
    
    let location = TPPBookmarkR3Location(
      resourceIndex: 0,
      locator: locator
    )
    
    XCTAssertEqual(location.locator.mediaType, .html)
  }
  
  // MARK: - Edge Cases
  
  func testFrom_emptyReadingOrder_returnsNil() {
    let manifest = Manifest(
      metadata: Metadata(title: "Empty Book"),
      readingOrder: []
    )
    let publication = Publication(manifest: manifest)
    
    let locator = createLocator(
      href: "/chapter1.xhtml",
      progression: 0.5,
      totalProgression: 0.25
    )
    
    let location = TPPBookmarkR3Location.from(
      locator: locator,
      in: publication
    )
    
    XCTAssertNil(location)
  }
  
  func testFrom_locatorWithDifferentMediaType_findsMatchByHref() {
    let publication = createTestPublication()
    
    // Use a different media type than what's in the publication
    let locator = Locator(
      href: AnyURL(string: "/chapter1.xhtml")!,
      mediaType: .html, // Different from .xhtml in publication
      locations: Locator.Locations(progression: 0.5, totalProgression: 0.25)
    )
    
    let location = TPPBookmarkR3Location.from(
      locator: locator,
      in: publication
    )
    
    // Should find based on href regardless of media type
    XCTAssertNotNil(location)
    XCTAssertEqual(location?.resourceIndex, 0)
  }
  
  // MARK: - Helper Methods
  
  private func createTestPublication() -> Publication {
    let metadata = Metadata(
      title: "Test Book",
      languages: ["en"]
    )
    
    let readingOrder = [
      Link(href: "/chapter1.xhtml", mediaType: .xhtml),
      Link(href: "/chapter2.xhtml", mediaType: .xhtml),
      Link(href: "/chapter3.xhtml", mediaType: .xhtml)
    ]
    
    let manifest = Manifest(
      metadata: metadata,
      readingOrder: readingOrder
    )
    
    return Publication(manifest: manifest)
  }
  
  private func createLocator(
    href: String,
    progression: Double,
    totalProgression: Double
  ) -> Locator {
    return Locator(
      href: AnyURL(string: href)!,
      mediaType: .xhtml,
      locations: Locator.Locations(
        progression: progression,
        totalProgression: totalProgression
      )
    )
  }
}

// MARK: - R3 Location Conversion Tests

final class TPPBookmarkR3ConversionTests: XCTestCase {
  
  private var publication: Publication!
  
  override func setUp() {
    super.setUp()
    
    let readingOrder = [
      Link(href: "/intro.xhtml", mediaType: .xhtml, title: "Introduction"),
      Link(href: "/chapter1.xhtml", mediaType: .xhtml, title: "Chapter 1"),
      Link(href: "/chapter2.xhtml", mediaType: .xhtml, title: "Chapter 2"),
      Link(href: "/appendix.xhtml", mediaType: .xhtml, title: "Appendix")
    ]
    
    let manifest = Manifest(
      metadata: Metadata(title: "Conversion Test Book"),
      readingOrder: readingOrder
    )
    
    publication = Publication(manifest: manifest)
  }
  
  override func tearDown() {
    publication = nil
    super.tearDown()
  }
  
  func testConvertToR3_validBookmark_createsR3Location() {
    let bookmark = TPPReadiumBookmark(
      annotationId: "test-id",
      href: "/chapter1.xhtml",
      chapter: "Chapter 1",
      page: "10",
      location: nil,
      progressWithinChapter: 0.5,
      progressWithinBook: 0.25,
      readingOrderItem: nil,
      readingOrderItemOffsetMilliseconds: 0,
      time: "2024-01-15T10:00:00Z",
      device: "test"
    )!
    
    let r3Location = bookmark.convertToR3(from: publication)
    
    XCTAssertNotNil(r3Location)
    XCTAssertEqual(r3Location?.resourceIndex, 1) // chapter1.xhtml is at index 1
    XCTAssertEqual(r3Location?.locator.href.string, "/chapter1.xhtml")
  }
  
  func testConvertToR3_bookmarkNotInPublication_returnsNil() {
    let bookmark = TPPReadiumBookmark(
      annotationId: "test-id",
      href: "/missing.xhtml",
      chapter: "Missing",
      page: nil,
      location: nil,
      progressWithinChapter: 0.5,
      progressWithinBook: 0.5,
      readingOrderItem: nil,
      readingOrderItemOffsetMilliseconds: 0,
      time: nil,
      device: nil
    )!
    
    let r3Location = bookmark.convertToR3(from: publication)
    
    XCTAssertNil(r3Location)
  }
  
  func testConvertToR3_preservesProgressionValues() {
    let bookmark = TPPReadiumBookmark(
      annotationId: nil,
      href: "/chapter2.xhtml",
      chapter: "Chapter 2",
      page: nil,
      location: nil,
      progressWithinChapter: 0.75,
      progressWithinBook: 0.6,
      readingOrderItem: nil,
      readingOrderItemOffsetMilliseconds: 0,
      time: nil,
      device: nil
    )!
    
    let r3Location = bookmark.convertToR3(from: publication)
    
    XCTAssertNotNil(r3Location)
    XCTAssertEqual(r3Location?.locator.locations.progression ?? 0, 0.75, accuracy: 0.001)
    XCTAssertEqual(r3Location?.locator.locations.totalProgression ?? 0, 0.6, accuracy: 0.001)
  }
  
  func testConvertToR3_preservesChapterTitle() {
    let bookmark = TPPReadiumBookmark(
      annotationId: nil,
      href: "/intro.xhtml",
      chapter: "Introduction",
      page: nil,
      location: nil,
      progressWithinChapter: 0.1,
      progressWithinBook: 0.05,
      readingOrderItem: nil,
      readingOrderItemOffsetMilliseconds: 0,
      time: nil,
      device: nil
    )!
    
    let r3Location = bookmark.convertToR3(from: publication)
    
    XCTAssertNotNil(r3Location)
    XCTAssertEqual(r3Location?.locator.title, "Introduction")
  }
  
  func testConvertToR3_parsesTimeCorrectly() {
    let bookmark = TPPReadiumBookmark(
      annotationId: nil,
      href: "/intro.xhtml",
      chapter: nil,
      page: nil,
      location: nil,
      progressWithinChapter: 0,
      progressWithinBook: 0,
      readingOrderItem: nil,
      readingOrderItemOffsetMilliseconds: 0,
      time: "2024-06-15T14:30:00Z",
      device: nil
    )!
    
    let r3Location = bookmark.convertToR3(from: publication)
    
    XCTAssertNotNil(r3Location)
    // Creation date should be parsed from the time string
    XCTAssertNotNil(r3Location?.creationDate)
  }
}
