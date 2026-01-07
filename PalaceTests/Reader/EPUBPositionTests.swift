//
//  EPUBPositionTests.swift
//  PalaceTests
//
//  Tests for TPPBookLocation creation, serialization, and throttling.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class EPUBPositionTests: XCTestCase {
  
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
  
  // MARK: - Location Comparison Tests
  
  func testLocationSimilarity_IdenticalLocations() {
    let location1 = TPPBookLocation(
      locationString: "{\"href\":\"/chapter.xhtml\",\"progression\":0.5}",
      renderer: TPPBookLocation.r3Renderer
    )!
    
    let location2 = TPPBookLocation(
      locationString: "{\"href\":\"/chapter.xhtml\",\"progression\":0.5}",
      renderer: TPPBookLocation.r3Renderer
    )!
    
    XCTAssertEqual(location1.locationString, location2.locationString)
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
    
    XCTAssertNotEqual(location1.locationString, location2.locationString)
  }
  
  // MARK: - Throttling Constant Tests
  
  func testThrottlingInterval_Value() {
    let expectedInterval: TimeInterval = 15.0
    
    XCTAssertEqual(TPPLastReadPositionPoster.throttlingInterval, expectedInterval)
  }
}
