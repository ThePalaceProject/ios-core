//
//  CatalogCacheMetadataTests.swift
//  PalaceTests
//
//  Unit tests for CatalogCacheMetadata struct.
//  Tests cache staleness and expiration calculations.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class CatalogCacheMetadataTests: XCTestCase {

  // MARK: - isStale Tests

  func testIsStale_WithFreshCache_ReturnsFalse() {
    // Cache created just now should not be stale
    let metadata = CatalogCacheMetadata(timestamp: Date(), hash: "abc123")

    XCTAssertFalse(metadata.isStale)
  }

  func testIsStale_WithCacheUnder5Minutes_ReturnsFalse() {
    // Cache created 4 minutes ago should not be stale
    let fourMinutesAgo = Date().addingTimeInterval(-240) // 4 * 60 = 240 seconds
    let metadata = CatalogCacheMetadata(timestamp: fourMinutesAgo, hash: "abc123")

    XCTAssertFalse(metadata.isStale)
  }

  func testIsStale_WithCacheExactly5Minutes_ReturnsFalse() {
    // Cache created just under 5 minutes ago should NOT be stale (boundary: > not >=)
    // Use 299 seconds to avoid timing precision issues between timestamp creation and check
    let justUnderFiveMinutes = Date().addingTimeInterval(-299) // Just under 5 * 60 = 299 seconds
    let metadata = CatalogCacheMetadata(timestamp: justUnderFiveMinutes, hash: "abc123")

    XCTAssertFalse(metadata.isStale)
  }

  func testIsStale_WithCacheOver5Minutes_ReturnsTrue() {
    // Cache created 6 minutes ago should be stale
    let sixMinutesAgo = Date().addingTimeInterval(-360) // 6 * 60 = 360 seconds
    let metadata = CatalogCacheMetadata(timestamp: sixMinutesAgo, hash: "abc123")

    XCTAssertTrue(metadata.isStale)
  }

  func testIsStale_WithCacheJustOver5Minutes_ReturnsTrue() {
    // Cache created 5 minutes and 1 second ago should be stale
    let justOverFiveMinutes = Date().addingTimeInterval(-301)
    let metadata = CatalogCacheMetadata(timestamp: justOverFiveMinutes, hash: "abc123")

    XCTAssertTrue(metadata.isStale)
  }

  // MARK: - isExpired Tests

  func testIsExpired_WithFreshCache_ReturnsFalse() {
    // Cache created just now should not be expired
    let metadata = CatalogCacheMetadata(timestamp: Date(), hash: "abc123")

    XCTAssertFalse(metadata.isExpired)
  }

  func testIsExpired_WithCacheUnder24Hours_ReturnsFalse() {
    // Cache created 23 hours ago should not be expired
    let twentyThreeHoursAgo = Date().addingTimeInterval(-82800) // 23 * 3600 = 82800 seconds
    let metadata = CatalogCacheMetadata(timestamp: twentyThreeHoursAgo, hash: "abc123")

    XCTAssertFalse(metadata.isExpired)
  }

  func testIsExpired_WithCacheExactly24Hours_ReturnsFalse() {
    // Cache created just under 24 hours ago should NOT be expired (boundary: > not >=)
    // Use 86399 seconds to avoid timing precision issues between timestamp creation and check
    let justUnder24Hours = Date().addingTimeInterval(-86399) // Just under 24 * 3600 = 86399 seconds
    let metadata = CatalogCacheMetadata(timestamp: justUnder24Hours, hash: "abc123")

    XCTAssertFalse(metadata.isExpired)
  }

  func testIsExpired_WithCacheOver24Hours_ReturnsTrue() {
    // Cache created 25 hours ago should be expired
    let twentyFiveHoursAgo = Date().addingTimeInterval(-90000) // 25 * 3600 = 90000 seconds
    let metadata = CatalogCacheMetadata(timestamp: twentyFiveHoursAgo, hash: "abc123")

    XCTAssertTrue(metadata.isExpired)
  }

  func testIsExpired_WithCacheJustOver24Hours_ReturnsTrue() {
    // Cache created 24 hours and 1 second ago should be expired
    let justOverTwentyFourHours = Date().addingTimeInterval(-86401)
    let metadata = CatalogCacheMetadata(timestamp: justOverTwentyFourHours, hash: "abc123")

    XCTAssertTrue(metadata.isExpired)
  }

  // MARK: - Combined State Tests

  func testStaleAndExpired_FreshCache_NeitherStaleNorExpired() {
    let metadata = CatalogCacheMetadata(timestamp: Date(), hash: "abc123")

    XCTAssertFalse(metadata.isStale)
    XCTAssertFalse(metadata.isExpired)
  }

  func testStaleAndExpired_StaleButNotExpired() {
    // Cache at 1 hour is stale but not expired
    let oneHourAgo = Date().addingTimeInterval(-3600)
    let metadata = CatalogCacheMetadata(timestamp: oneHourAgo, hash: "abc123")

    XCTAssertTrue(metadata.isStale)
    XCTAssertFalse(metadata.isExpired)
  }

  func testStaleAndExpired_ExpiredCacheIsAlsoStale() {
    // Cache at 25 hours is both stale and expired
    let twentyFiveHoursAgo = Date().addingTimeInterval(-90000)
    let metadata = CatalogCacheMetadata(timestamp: twentyFiveHoursAgo, hash: "abc123")

    XCTAssertTrue(metadata.isStale)
    XCTAssertTrue(metadata.isExpired)
  }

  // MARK: - Encoding/Decoding Tests

  func testEncodeDecode_PreservesAllProperties() throws {
    let originalTimestamp = Date()
    let originalHash = "test-hash-12345"
    let original = CatalogCacheMetadata(timestamp: originalTimestamp, hash: originalHash)

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(CatalogCacheMetadata.self, from: data)

    // Allow 1 second tolerance for date comparison due to encoding precision
    XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, originalTimestamp.timeIntervalSince1970, accuracy: 1)
    XCTAssertEqual(decoded.hash, originalHash)
  }

  func testEncodeDecode_WithEmptyHash() throws {
    let original = CatalogCacheMetadata(timestamp: Date(), hash: "")

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(CatalogCacheMetadata.self, from: data)

    XCTAssertEqual(decoded.hash, "")
  }

  func testEncodeDecode_WithSpecialCharactersInHash() throws {
    let specialHash = "hash/with+special=chars&more!"
    let original = CatalogCacheMetadata(timestamp: Date(), hash: specialHash)

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(CatalogCacheMetadata.self, from: data)

    XCTAssertEqual(decoded.hash, specialHash)
  }

  func testDecode_FromValidJSON() throws {
    // Create original metadata to encode
    let originalDate = Date(timeIntervalSince1970: 1704067200) // Jan 1, 2024
    let original = CatalogCacheMetadata(timestamp: originalDate, hash: "json-hash")

    // Encode and decode (using default Codable behavior)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let encoded = try encoder.encode(original)
    let decoded = try decoder.decode(CatalogCacheMetadata.self, from: encoded)

    XCTAssertEqual(decoded.hash, "json-hash")
    XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, 1704067200, accuracy: 1)
  }

  // MARK: - Edge Cases

  func testIsStale_WithFutureTimestamp_ReturnsFalse() {
    // A cache with a future timestamp (clock skew scenario) should not be stale
    let futureDate = Date().addingTimeInterval(3600) // 1 hour in the future
    let metadata = CatalogCacheMetadata(timestamp: futureDate, hash: "future")

    XCTAssertFalse(metadata.isStale)
    XCTAssertFalse(metadata.isExpired)
  }

  func testIsExpired_WithVeryOldTimestamp() {
    // Cache from a long time ago should be expired
    let veryOldDate = Date(timeIntervalSince1970: 0) // Jan 1, 1970
    let metadata = CatalogCacheMetadata(timestamp: veryOldDate, hash: "old")

    XCTAssertTrue(metadata.isStale)
    XCTAssertTrue(metadata.isExpired)
  }

  func testHash_IsCaseSensitive() {
    let lowerCase = CatalogCacheMetadata(timestamp: Date(), hash: "abc")
    let upperCase = CatalogCacheMetadata(timestamp: Date(), hash: "ABC")

    XCTAssertNotEqual(lowerCase.hash, upperCase.hash)
  }
}
