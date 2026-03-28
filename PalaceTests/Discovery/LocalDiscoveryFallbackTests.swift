//
//  LocalDiscoveryFallbackTests.swift
//  PalaceTests
//
//  Tests for LocalDiscoveryFallback offline recommendation engine.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class LocalDiscoveryFallbackTests: XCTestCase {

  private var fallback: LocalDiscoveryFallback!
  private var mockBookRegistry: TPPBookRegistryMock!

  override func setUp() {
    super.setUp()
    mockBookRegistry = TPPBookRegistryMock()
    fallback = LocalDiscoveryFallback(bookRegistry: mockBookRegistry)
  }

  override func tearDown() {
    fallback = nil
    mockBookRegistry = nil
    super.tearDown()
  }

  // MARK: - Availability

  func testIsAvailable_AlwaysTrue() {
    XCTAssertTrue(fallback.isAvailable)
  }

  // MARK: - Mood-Based Recommendations

  func testMoodRecommendations_ReturnsResultsForEachMood() async throws {
    for mood in ReadingMood.allCases {
      let prompt = DiscoveryPrompt(mood: mood)
      let results = try await fallback.getRecommendations(prompt: prompt)

      XCTAssertFalse(results.isEmpty, "Should return recommendations for mood: \(mood)")
    }
  }

  func testMoodRecommendations_ContainRelevantCategories() async throws {
    let prompt = DiscoveryPrompt(mood: .thrilling)
    let results = try await fallback.getRecommendations(prompt: prompt)

    let allCategories = results.flatMap(\.categories)
    // Thrilling mood should map to thriller-related categories
    let thrillerCategories = ["Thriller", "Mystery", "Horror", "Suspense", "Crime Fiction"]
    let hasThrillerCategory = allCategories.contains { thrillerCategories.contains($0) }
    XCTAssertTrue(hasThrillerCategory, "Thrilling mood should include thriller categories")
  }

  // MARK: - Genre-Based Recommendations

  func testGenreRecommendations_ReturnsResultsForGenres() async throws {
    let prompt = DiscoveryPrompt(genres: ["Science Fiction", "Fantasy"])
    let results = try await fallback.getRecommendations(prompt: prompt)

    XCTAssertEqual(results.count, 2)
    XCTAssertTrue(results[0].categories.contains("Science Fiction"))
    XCTAssertTrue(results[1].categories.contains("Fantasy"))
  }

  // MARK: - History-Based Recommendations

  func testHistoryRecommendations_ReturnsResultsFromReadingHistory() async throws {
    let history = [
      ReadingHistoryItem(title: "Dune", authors: ["Frank Herbert"], categories: ["Science Fiction"]),
      ReadingHistoryItem(title: "Foundation", authors: ["Isaac Asimov"], categories: ["Science Fiction"]),
      ReadingHistoryItem(title: "1984", authors: ["George Orwell"], categories: ["Dystopian"]),
    ]
    let prompt = DiscoveryPrompt(readingHistory: history)
    let results = try await fallback.getRecommendations(prompt: prompt)

    XCTAssertFalse(results.isEmpty, "Should generate recommendations from reading history")
  }

  func testHistoryRecommendations_FavorsFrequentCategories() async throws {
    let history = [
      ReadingHistoryItem(title: "Book 1", authors: [], categories: ["Mystery"]),
      ReadingHistoryItem(title: "Book 2", authors: [], categories: ["Mystery"]),
      ReadingHistoryItem(title: "Book 3", authors: [], categories: ["Mystery"]),
      ReadingHistoryItem(title: "Book 4", authors: [], categories: ["Romance"]),
    ]
    let prompt = DiscoveryPrompt(readingHistory: history)
    let results = try await fallback.getRecommendations(prompt: prompt)

    // Mystery should appear first since it's most frequent
    XCTAssertFalse(results.isEmpty)
    let firstCategories = results.first?.categories ?? []
    XCTAssertTrue(firstCategories.contains("Mystery"))
  }

  // MARK: - Surprise Me (Free text nil, mood nil, genres empty)

  func testSurpriseMe_WithHistory_GeneratesRecommendations() async throws {
    let history = [
      ReadingHistoryItem(title: "The Great Gatsby", authors: ["F. Scott Fitzgerald"], categories: ["Literary Fiction"]),
    ]
    let prompt = DiscoveryPrompt.surpriseMe(history: history)
    let results = try await fallback.getRecommendations(prompt: prompt)

    XCTAssertFalse(results.isEmpty)
  }

  // MARK: - Free Text Search

  func testFreeTextSearch_MatchesTitleInHistory() async throws {
    let history = [
      ReadingHistoryItem(title: "Harry Potter", authors: ["J.K. Rowling"], categories: ["Fantasy"]),
      ReadingHistoryItem(title: "Lord of the Rings", authors: ["J.R.R. Tolkien"], categories: ["Fantasy"]),
    ]
    let prompt = DiscoveryPrompt(freeText: "Harry", readingHistory: history)
    let results = try await fallback.getRecommendations(prompt: prompt)

    XCTAssertFalse(results.isEmpty)
    // Should match "Harry Potter" from history
    let hasHarryMatch = results.contains { $0.title.contains("Harry Potter") }
    XCTAssertTrue(hasHarryMatch)
  }

  func testFreeTextSearch_MatchesAuthorInHistory() async throws {
    let history = [
      ReadingHistoryItem(title: "Some Book", authors: ["Stephen King"], categories: ["Horror"]),
    ]
    let prompt = DiscoveryPrompt(freeText: "Stephen", readingHistory: history)
    let results = try await fallback.getRecommendations(prompt: prompt)

    XCTAssertFalse(results.isEmpty)
  }

  // MARK: - Empty History

  func testEmptyHistory_NoMoodNoText_ReturnsEmpty() async throws {
    let prompt = DiscoveryPrompt()
    let results = try await fallback.getRecommendations(prompt: prompt)

    XCTAssertTrue(results.isEmpty, "No context at all should yield empty results")
  }

  // MARK: - Confidence Scores

  func testRecommendations_HaveValidConfidenceScores() async throws {
    let prompt = DiscoveryPrompt(mood: .relaxing)
    let results = try await fallback.getRecommendations(prompt: prompt)

    for rec in results {
      XCTAssertGreaterThanOrEqual(rec.confidenceScore, 0.0, "Confidence must be >= 0")
      XCTAssertLessThanOrEqual(rec.confidenceScore, 1.0, "Confidence must be <= 1")
    }
  }

  // MARK: - No Duplicate Recommendations

  func testRecommendations_NoDuplicateIDs() async throws {
    let history = [
      ReadingHistoryItem(title: "Book", authors: ["Author"], categories: ["Fiction"]),
    ]
    let prompt = DiscoveryPrompt(
      freeText: "Fiction",
      mood: .relaxing,
      genres: ["Fiction"],
      readingHistory: history
    )
    let results = try await fallback.getRecommendations(prompt: prompt)

    let ids = results.map(\.id)
    XCTAssertEqual(ids.count, Set(ids).count, "Should not have duplicate recommendation IDs")
  }

  // MARK: - Max Results

  func testRecommendations_RespectMaxResults() async throws {
    let prompt = DiscoveryPrompt(
      mood: .educational,
      genres: ["Science", "History", "Math", "Physics", "Chemistry"],
      maxResults: 3
    )
    let results = try await fallback.getRecommendations(prompt: prompt)

    XCTAssertLessThanOrEqual(results.count, 3)
  }
}
