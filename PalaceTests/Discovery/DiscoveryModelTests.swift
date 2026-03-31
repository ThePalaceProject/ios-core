//
//  DiscoveryModelTests.swift
//  PalaceTests
//
//  Tests for Discovery model types: DiscoveryPrompt, DiscoveryRecommendation,
//  LibrarySearchResult, CrossLibrarySearchResponse, and ReadingMood.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - DiscoveryPrompt Tests

final class DiscoveryPromptTests: XCTestCase {

  func testInit_DefaultValues() {
    let prompt = DiscoveryPrompt()

    XCTAssertNil(prompt.freeText)
    XCTAssertNil(prompt.mood)
    XCTAssertTrue(prompt.genres.isEmpty)
    XCTAssertTrue(prompt.readingHistory.isEmpty)
    XCTAssertEqual(prompt.maxResults, 20)
  }

  func testInit_CustomValues() {
    let history = [ReadingHistoryItem(title: "Book", authors: ["Author"], categories: ["Fiction"])]
    let prompt = DiscoveryPrompt(
      freeText: "mystery books",
      mood: .thrilling,
      genres: ["Mystery", "Thriller"],
      readingHistory: history,
      maxResults: 5
    )

    XCTAssertEqual(prompt.freeText, "mystery books")
    XCTAssertEqual(prompt.mood, .thrilling)
    XCTAssertEqual(prompt.genres, ["Mystery", "Thriller"])
    XCTAssertEqual(prompt.readingHistory.count, 1)
    XCTAssertEqual(prompt.maxResults, 5)
  }

  func testSurpriseMe_Factory() {
    let history = [
      ReadingHistoryItem(title: "Book A", authors: [], categories: []),
      ReadingHistoryItem(title: "Book B", authors: [], categories: []),
    ]
    let prompt = DiscoveryPrompt.surpriseMe(history: history)

    XCTAssertNil(prompt.freeText)
    XCTAssertNil(prompt.mood)
    XCTAssertTrue(prompt.genres.isEmpty)
    XCTAssertEqual(prompt.readingHistory.count, 2)
    XCTAssertEqual(prompt.maxResults, 10)
  }

  func testMoodBasedInit() {
    let prompt = DiscoveryPrompt(mood: .funny)

    XCTAssertNil(prompt.freeText)
    XCTAssertEqual(prompt.mood, .funny)
    XCTAssertTrue(prompt.genres.isEmpty)
    XCTAssertTrue(prompt.readingHistory.isEmpty)
  }

  func testEquatable() {
    let prompt1 = DiscoveryPrompt(freeText: "test", mood: .relaxing)
    let prompt2 = DiscoveryPrompt(freeText: "test", mood: .relaxing)
    let prompt3 = DiscoveryPrompt(freeText: "different", mood: .relaxing)

    XCTAssertEqual(prompt1, prompt2)
    XCTAssertNotEqual(prompt1, prompt3)
  }
}

// MARK: - DiscoveryRecommendation Tests

final class DiscoveryRecommendationTests: XCTestCase {

  private func makeRecommendation(
    id: String = "rec-1",
    availability: [LibraryAvailability] = []
  ) -> DiscoveryRecommendation {
    DiscoveryRecommendation(
      id: id,
      title: "Test Book",
      authors: ["Test Author"],
      summary: "A test summary",
      coverImageURL: nil,
      reason: "Because you like tests",
      confidenceScore: 0.85,
      categories: ["Fiction"],
      availability: availability
    )
  }

  private func makeAvailability(
    libraryId: String,
    libraryName: String,
    status: AvailabilityStatus
  ) -> LibraryAvailability {
    LibraryAvailability(
      libraryId: libraryId,
      libraryName: libraryName,
      status: status,
      copiesAvailable: status == .availableNow ? 1 : 0,
      copiesTotal: 5,
      holdPosition: nil,
      estimatedWaitDays: nil,
      opdsIdentifier: nil,
      borrowURL: nil
    )
  }

  func testBestAvailability_ReturnsUnavailable_WhenNoAvailability() {
    let rec = makeRecommendation(availability: [])
    XCTAssertEqual(rec.bestAvailability, .unavailable)
  }

  func testBestAvailability_ReturnsBest() {
    let rec = makeRecommendation(availability: [
      makeAvailability(libraryId: "1", libraryName: "Lib A", status: .longWait),
      makeAvailability(libraryId: "2", libraryName: "Lib B", status: .availableNow),
      makeAvailability(libraryId: "3", libraryName: "Lib C", status: .shortWait),
    ])
    XCTAssertEqual(rec.bestAvailability, .availableNow)
  }

  func testBestLibraryName_ReturnsLibraryWithBestAvailability() {
    let rec = makeRecommendation(availability: [
      makeAvailability(libraryId: "1", libraryName: "Slow Library", status: .longWait),
      makeAvailability(libraryId: "2", libraryName: "Fast Library", status: .availableNow),
    ])
    XCTAssertEqual(rec.bestLibraryName, "Fast Library")
  }

  func testBestLibraryName_Nil_WhenNoAvailability() {
    let rec = makeRecommendation(availability: [])
    XCTAssertNil(rec.bestLibraryName)
  }

  func testIdentifiable_UsesId() {
    let rec = makeRecommendation(id: "unique-id")
    XCTAssertEqual(rec.id, "unique-id")
  }

  func testEquatable() {
    let rec1 = makeRecommendation(id: "1")
    let rec2 = makeRecommendation(id: "1")
    let rec3 = makeRecommendation(id: "2")

    XCTAssertEqual(rec1, rec2)
    XCTAssertNotEqual(rec1, rec3)
  }
}

// MARK: - AvailabilityStatus Tests

final class AvailabilityStatusTests: XCTestCase {

  func testComparable_Ordering() {
    XCTAssertTrue(AvailabilityStatus.availableNow < .shortWait)
    XCTAssertTrue(AvailabilityStatus.shortWait < .longWait)
    XCTAssertTrue(AvailabilityStatus.longWait < .unavailable)
  }

  func testAllCases() {
    XCTAssertEqual(AvailabilityStatus.allCases.count, 4)
  }

  func testDisplayLabel_NotEmpty() {
    for status in AvailabilityStatus.allCases {
      XCTAssertFalse(status.displayLabel.isEmpty, "\(status) should have a display label")
    }
  }

  func testAccessibilityLabel_NotEmpty() {
    for status in AvailabilityStatus.allCases {
      XCTAssertFalse(status.accessibilityLabel.isEmpty, "\(status) should have an accessibility label")
    }
  }
}

// MARK: - LibrarySearchResult Tests

final class LibrarySearchResultTests: XCTestCase {

  func testId_IsCompositeOfLibraryAndBook() {
    let result = LibrarySearchResult(
      libraryId: "nypl",
      libraryName: "NYPL",
      bookIdentifier: "book-123",
      title: "Test",
      authors: [],
      summary: nil,
      categories: [],
      coverImageURL: nil,
      thumbnailURL: nil,
      availability: .availableNow,
      copiesAvailable: 1,
      copiesTotal: 5,
      holdPosition: nil,
      published: nil,
      publisher: nil,
      borrowURL: nil,
      format: .epub,
      book: nil
    )

    XCTAssertEqual(result.id, "nypl:book-123")
  }

  func testBookFormat_AllCases() {
    XCTAssertEqual(BookFormat.allCases.count, 4)
    XCTAssertEqual(BookFormat.epub.displayName, "EPUB")
    XCTAssertEqual(BookFormat.pdf.displayName, "PDF")
    XCTAssertEqual(BookFormat.audiobook.displayName, "Audiobook")
    XCTAssertEqual(BookFormat.unknown.displayName, "Unknown")
  }
}

// MARK: - CrossLibrarySearchResponse Tests

final class CrossLibrarySearchResponseTests: XCTestCase {

  private func makeMergedResult(
    id: String,
    title: String,
    availability: AvailabilityStatus = .availableNow
  ) -> CrossLibrarySearchResponse.MergedSearchResult {
    let libraryResult = LibrarySearchResult(
      libraryId: "lib-1",
      libraryName: "Library One",
      bookIdentifier: id,
      title: title,
      authors: [],
      summary: nil,
      categories: [],
      coverImageURL: nil,
      thumbnailURL: nil,
      availability: availability,
      copiesAvailable: nil,
      copiesTotal: nil,
      holdPosition: nil,
      published: nil,
      publisher: nil,
      borrowURL: nil,
      format: .epub,
      book: nil
    )
    return CrossLibrarySearchResponse.MergedSearchResult(
      id: id,
      title: title,
      authors: [],
      summary: nil,
      categories: [],
      coverImageURL: nil,
      thumbnailURL: nil,
      published: nil,
      publisher: nil,
      format: .epub,
      libraryResults: [libraryResult]
    )
  }

  func testTotalResults_CountsUniqueResults() {
    let response = CrossLibrarySearchResponse(
      query: "test",
      results: [
        makeMergedResult(id: "1", title: "Book A"),
        makeMergedResult(id: "2", title: "Book B"),
      ],
      searchedLibraries: [],
      timestamp: Date()
    )

    XCTAssertEqual(response.totalResults, 2)
  }

  func testAvailableNow_FiltersCorrectly() {
    let response = CrossLibrarySearchResponse(
      query: "test",
      results: [
        makeMergedResult(id: "1", title: "Available", availability: .availableNow),
        makeMergedResult(id: "2", title: "Waiting", availability: .longWait),
        makeMergedResult(id: "3", title: "Also Available", availability: .availableNow),
      ],
      searchedLibraries: [],
      timestamp: Date()
    )

    XCTAssertEqual(response.availableNow.count, 2)
  }

  func testMergedResult_LibraryCount() {
    let lib1Result = LibrarySearchResult(
      libraryId: "lib-1", libraryName: "Library 1", bookIdentifier: "book-1",
      title: "Book", authors: [], summary: nil, categories: [],
      coverImageURL: nil, thumbnailURL: nil, availability: .availableNow,
      copiesAvailable: nil, copiesTotal: nil, holdPosition: nil,
      published: nil, publisher: nil, borrowURL: nil, format: .epub, book: nil
    )
    let lib2Result = LibrarySearchResult(
      libraryId: "lib-2", libraryName: "Library 2", bookIdentifier: "book-1",
      title: "Book", authors: [], summary: nil, categories: [],
      coverImageURL: nil, thumbnailURL: nil, availability: .shortWait,
      copiesAvailable: nil, copiesTotal: nil, holdPosition: nil,
      published: nil, publisher: nil, borrowURL: nil, format: .epub, book: nil
    )
    let merged = CrossLibrarySearchResponse.MergedSearchResult(
      id: "book-1", title: "Book", authors: [], summary: nil,
      categories: [], coverImageURL: nil, thumbnailURL: nil,
      published: nil, publisher: nil, format: .epub,
      libraryResults: [lib1Result, lib2Result]
    )

    XCTAssertEqual(merged.libraryCount, 2)
    XCTAssertEqual(merged.bestAvailability, .availableNow)
    XCTAssertEqual(merged.bestResult?.libraryId, "lib-1")
  }

  func testSearchedLibrary_Identifiable() {
    let library = CrossLibrarySearchResponse.SearchedLibrary(
      id: "lib-1", name: "Test Library", succeeded: true, resultCount: 42
    )

    XCTAssertEqual(library.id, "lib-1")
    XCTAssertEqual(library.name, "Test Library")
    XCTAssertTrue(library.succeeded)
    XCTAssertEqual(library.resultCount, 42)
  }
}

// MARK: - ReadingMood Tests

final class ReadingMoodTests: XCTestCase {

  func testAllCases_HaveSystemImageNames() {
    for mood in ReadingMood.allCases {
      XCTAssertFalse(mood.systemImageName.isEmpty, "\(mood) should have a system image name")
    }
  }

  func testAllCases_HaveDisplayNames() {
    for mood in ReadingMood.allCases {
      XCTAssertFalse(mood.displayName.isEmpty, "\(mood) should have a display name")
    }
  }

  func testAllCases_Count() {
    XCTAssertEqual(ReadingMood.allCases.count, 7)
  }

  func testIdentifiable_UsesRawValue() {
    for mood in ReadingMood.allCases {
      XCTAssertEqual(mood.id, mood.rawValue)
    }
  }

  func testEmoji_NotEmpty() {
    for mood in ReadingMood.allCases {
      XCTAssertFalse(mood.emoji.isEmpty, "\(mood) should have an emoji description")
    }
  }

  func testSpecificMoodValues() {
    XCTAssertEqual(ReadingMood.relaxing.systemImageName, "leaf")
    XCTAssertEqual(ReadingMood.thrilling.systemImageName, "bolt")
    XCTAssertEqual(ReadingMood.educational.systemImageName, "graduationcap")
    XCTAssertEqual(ReadingMood.inspiring.systemImageName, "sun.max")
    XCTAssertEqual(ReadingMood.funny.systemImageName, "face.smiling")
    XCTAssertEqual(ReadingMood.shortReads.systemImageName, "clock")
    XCTAssertEqual(ReadingMood.deepDive.systemImageName, "book")
  }
}

// MARK: - ReadingHistoryItem Tests

final class ReadingHistoryItemTests: XCTestCase {

  func testInit() {
    let item = ReadingHistoryItem(
      title: "Test Book",
      authors: ["Author A", "Author B"],
      categories: ["Fiction", "Drama"]
    )

    XCTAssertEqual(item.title, "Test Book")
    XCTAssertEqual(item.authors, ["Author A", "Author B"])
    XCTAssertEqual(item.categories, ["Fiction", "Drama"])
  }

  func testEquatable() {
    let item1 = ReadingHistoryItem(title: "Book", authors: ["Author"], categories: ["Fiction"])
    let item2 = ReadingHistoryItem(title: "Book", authors: ["Author"], categories: ["Fiction"])
    let item3 = ReadingHistoryItem(title: "Other", authors: ["Author"], categories: ["Fiction"])

    XCTAssertEqual(item1, item2)
    XCTAssertNotEqual(item1, item3)
  }

  func testCodable_RoundTrip() throws {
    let original = ReadingHistoryItem(
      title: "Encoded Book",
      authors: ["Writer"],
      categories: ["Sci-Fi"]
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ReadingHistoryItem.self, from: data)

    XCTAssertEqual(original, decoded)
  }
}
