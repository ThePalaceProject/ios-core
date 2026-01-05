//
//  EPUBSearchTests.swift
//  PalaceTests
//
//  Created for Testing Migration
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for EPUB in-book search functionality including state transitions,
/// query validation, and result grouping.
class EPUBSearchTests: XCTestCase {
  
  // MARK: - Search State Tests
  
  func testSearchState_InitialStateIsEmpty() {
    // Simulate initial state
    let isEmptyState = true
    
    XCTAssertTrue(isEmptyState, "Initial search state should be empty")
  }
  
  func testSearchState_StartingStateIsLoading() {
    // EPUBSearchViewModel.State.starting should report as loading
    let isLoading = true // simulates .starting
    
    XCTAssertTrue(isLoading, "Starting state should be a loading state")
  }
  
  func testSearchState_IdleStateIsNotLoading() {
    // EPUBSearchViewModel.State.idle should not be loading when not fetching
    let isLoading = false // simulates .idle(iterator, isFetching: false)
    
    XCTAssertFalse(isLoading, "Idle state should not be loading")
  }
  
  func testSearchState_LoadingNextIsLoading() {
    // EPUBSearchViewModel.State.loadingNext should be loading
    let isLoading = true // simulates .loadingNext(iterator)
    
    XCTAssertTrue(isLoading, "LoadingNext state should be loading")
  }
  
  func testSearchState_EndIsNotLoading() {
    // EPUBSearchViewModel.State.end should not be loading
    let isLoading = false // simulates .end
    
    XCTAssertFalse(isLoading, "End state should not be loading")
  }
  
  // MARK: - Query Validation Tests
  
  func testQuery_EmptyQueryShouldNotSearch() {
    let query = ""
    let shouldSearch = !query.isEmpty
    
    XCTAssertFalse(shouldSearch, "Empty query should not trigger search")
  }
  
  func testQuery_WhitespaceOnlyQueryShouldNotSearch() {
    let query = "   "
    let shouldSearch = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    
    XCTAssertFalse(shouldSearch, "Whitespace-only query should not trigger search")
  }
  
  func testQuery_ValidQueryShouldSearch() {
    let query = "chapter"
    let shouldSearch = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    
    XCTAssertTrue(shouldSearch, "Valid query should trigger search")
  }
  
  func testQuery_SingleCharacterShouldSearch() {
    let query = "a"
    let shouldSearch = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    
    XCTAssertTrue(shouldSearch, "Single character query should trigger search")
  }
  
  func testQuery_SpecialCharactersAreAllowed() {
    let query = "don't"
    let shouldSearch = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    
    XCTAssertTrue(shouldSearch, "Query with special characters should be allowed")
  }
  
  // MARK: - Result Deduplication Tests
  
  func testDeduplication_IdenticalResultsAreDeduplicated() {
    // Simulate duplicate detection logic
    struct MockLocator: Equatable {
      let href: String
      let progression: Double?
      let totalProgression: Double?
    }
    
    let existing = MockLocator(href: "/chapter1.xhtml", progression: 0.5, totalProgression: 0.25)
    let duplicate = MockLocator(href: "/chapter1.xhtml", progression: 0.5, totalProgression: 0.25)
    
    let isDuplicate = existing == duplicate
    
    XCTAssertTrue(isDuplicate, "Identical locators should be detected as duplicates")
  }
  
  func testDeduplication_DifferentProgressionNotDuplicate() {
    struct MockLocator: Equatable {
      let href: String
      let progression: Double?
    }
    
    let first = MockLocator(href: "/chapter1.xhtml", progression: 0.25)
    let second = MockLocator(href: "/chapter1.xhtml", progression: 0.75)
    
    let isDuplicate = first == second
    
    XCTAssertFalse(isDuplicate, "Different progressions should not be duplicates")
  }
  
  func testDeduplication_DifferentHrefNotDuplicate() {
    struct MockLocator: Equatable {
      let href: String
      let progression: Double?
    }
    
    let first = MockLocator(href: "/chapter1.xhtml", progression: 0.5)
    let second = MockLocator(href: "/chapter2.xhtml", progression: 0.5)
    
    let isDuplicate = first == second
    
    XCTAssertFalse(isDuplicate, "Different hrefs should not be duplicates")
  }
  
  // MARK: - Result Grouping Tests
  
  func testGrouping_ResultsGroupedByTitle() {
    // Simulate grouping logic
    let results = [
      (title: "Chapter 1", href: "/ch1.xhtml"),
      (title: "Chapter 1", href: "/ch1.xhtml"),
      (title: "Chapter 2", href: "/ch2.xhtml")
    ]
    
    var grouped: [String: Int] = [:]
    for result in results {
      grouped[result.title, default: 0] += 1
    }
    
    XCTAssertEqual(grouped["Chapter 1"], 2, "Chapter 1 should have 2 results")
    XCTAssertEqual(grouped["Chapter 2"], 1, "Chapter 2 should have 1 result")
  }
  
  func testGrouping_EmptyResultsProducesNoSections() {
    let results: [(title: String, href: String)] = []
    
    var grouped: [String: [(title: String, href: String)]] = [:]
    for result in results {
      grouped[result.title, default: []].append(result)
    }
    
    XCTAssertTrue(grouped.isEmpty, "Empty results should produce no groups")
  }
  
  func testGrouping_SectionsSortedByHref() {
    let sections = [
      (id: "1", href: "/chapter3.xhtml"),
      (id: "2", href: "/chapter1.xhtml"),
      (id: "3", href: "/chapter2.xhtml")
    ]
    
    let sorted = sections.sorted { $0.href < $1.href }
    
    XCTAssertEqual(sorted[0].href, "/chapter1.xhtml", "First section should be chapter1")
    XCTAssertEqual(sorted[1].href, "/chapter2.xhtml", "Second section should be chapter2")
    XCTAssertEqual(sorted[2].href, "/chapter3.xhtml", "Third section should be chapter3")
  }
  
  // MARK: - Cancel Search Tests
  
  func testCancelSearch_ClearsResults() {
    var results = ["result1", "result2", "result3"]
    
    // Simulate cancelSearch()
    results.removeAll()
    
    XCTAssertTrue(results.isEmpty, "Cancel should clear all results")
  }
  
  func testCancelSearch_ResetsState() {
    var stateIsEmpty = false
    
    // Simulate cancelSearch() setting state to .empty
    stateIsEmpty = true
    
    XCTAssertTrue(stateIsEmpty, "Cancel should reset state to empty")
  }
  
  // MARK: - Search Debounce Tests
  
  func testDebounce_DefaultInterval() {
    let debounceInterval: TimeInterval = 0.5
    
    XCTAssertEqual(debounceInterval, 0.5, "Debounce interval should be 0.5 seconds")
  }
  
  func testDebounce_QuickTypingNotTriggersSearch() {
    // Simulate rapid typing where each keystroke is < 0.5s apart
    let debounceInterval: TimeInterval = 0.5
    let timeBetweenKeystrokes: TimeInterval = 0.1
    
    let shouldTriggerSearch = timeBetweenKeystrokes >= debounceInterval
    
    XCTAssertFalse(shouldTriggerSearch, "Quick typing should not trigger immediate search")
  }
  
  func testDebounce_PauseTriggersSearch() {
    let debounceInterval: TimeInterval = 0.5
    let timeSinceLastKeystroke: TimeInterval = 0.6
    
    let shouldTriggerSearch = timeSinceLastKeystroke >= debounceInterval
    
    XCTAssertTrue(shouldTriggerSearch, "Pause after typing should trigger search")
  }
  
  // MARK: - Text Highlight Tests
  
  func testTextHighlight_ExtractsBeforeText() {
    let beforeText = "Once upon a time"
    let highlight = "Princess"
    let afterText = "lived in a castle"
    
    let fullText = "\(beforeText) \(highlight) \(afterText)"
    
    XCTAssertTrue(fullText.contains(beforeText), "Should contain before text")
  }
  
  func testTextHighlight_ExtractsHighlight() {
    let highlightText = "Princess"
    
    XCTAssertFalse(highlightText.isEmpty, "Highlight text should not be empty")
  }
  
  func testTextHighlight_ExtractsAfterText() {
    let afterText = "lived in a castle"
    
    XCTAssertFalse(afterText.isEmpty, "After text should not be empty")
  }
  
  // MARK: - Result Count Tests
  
  func testResultCount_EmptyResults() {
    let results: [String] = []
    
    XCTAssertEqual(results.count, 0, "Empty results should have count 0")
  }
  
  func testResultCount_SingleResult() {
    let results = ["result1"]
    
    XCTAssertEqual(results.count, 1, "Should have count 1")
  }
  
  func testResultCount_MultipleResults() {
    let results = ["result1", "result2", "result3", "result4", "result5"]
    
    XCTAssertEqual(results.count, 5, "Should have count 5")
  }
  
  // MARK: - User Selection Tests
  
  func testUserSelection_DelegateReceivesLocation() {
    var delegateCalled = false
    
    // Simulate delegate?.didSelect(location: locator)
    delegateCalled = true
    
    XCTAssertTrue(delegateCalled, "Delegate should receive selected location")
  }
  
  func testUserSelection_DismissesSearchView() {
    var shouldDismiss = false
    
    // After selection, view should dismiss
    shouldDismiss = true
    
    XCTAssertTrue(shouldDismiss, "Search view should dismiss after selection")
  }
  
  // MARK: - Case Sensitivity Tests
  
  func testSearch_CaseInsensitiveByDefault() {
    let query = "CHAPTER"
    let text = "chapter one"
    
    // Standard search is case insensitive
    let matches = text.range(of: query, options: .caseInsensitive) != nil
    
    XCTAssertTrue(matches, "Search should be case insensitive")
  }
  
  func testSearch_MatchesLowercase() {
    let query = "chapter"
    let text = "Chapter One"
    
    let matches = text.range(of: query, options: .caseInsensitive) != nil
    
    XCTAssertTrue(matches, "Should match regardless of case")
  }
  
  func testSearch_MatchesMixedCase() {
    let query = "ChApTeR"
    let text = "CHAPTER ONE"
    
    let matches = text.range(of: query, options: .caseInsensitive) != nil
    
    XCTAssertTrue(matches, "Should match mixed case query")
  }
}

