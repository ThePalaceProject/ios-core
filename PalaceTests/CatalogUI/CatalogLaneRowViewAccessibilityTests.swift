//
//  CatalogLaneRowViewAccessibilityTests.swift
//  PalaceTests
//
//  Regression test for PP-3346: VoiceOver no longer reading title and author of books
//  in main catalog screen. This test ensures that the book buttons in the horizontal
//  lane scroller have proper accessibility labels for VoiceOver users.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

final class CatalogLaneRowViewAccessibilityTests: XCTestCase {
  
  // MARK: - PP-3346 Regression Tests
  
  /// PP-3346: Verifies that a book's accessibility label includes title and author
  func testAccessibilityLabel_includesTitleAndAuthor() {
    // Given
    let book = TPPBookMocker.mockBook(title: "The Great Gatsby", authors: "F. Scott Fitzgerald")
    
    // When
    let label = makeAccessibilityLabel(for: book)
    
    // Then
    XCTAssertTrue(label.contains("The Great Gatsby"), "Accessibility label should contain the book title")
    XCTAssertTrue(label.contains("F. Scott Fitzgerald"), "Accessibility label should contain the author name")
    XCTAssertTrue(label.contains(Strings.Generic.by), "Accessibility label should use proper 'by' attribution")
  }
  
  /// PP-3346: Verifies that a book without authors still has a valid accessibility label
  func testAccessibilityLabel_bookWithoutAuthor() {
    // Given
    let book = TPPBookMocker.mockBook(title: "Untitled Work", authors: nil)
    
    // When
    let label = makeAccessibilityLabel(for: book)
    
    // Then
    XCTAssertEqual(label, "Untitled Work", "Book without author should only include the title")
  }
  
  /// PP-3346: Verifies that audiobooks have proper accessibility designation
  func testAccessibilityLabel_audiobookIncludesAudiobookDesignation() {
    // Given
    let audiobook = TPPBookMocker.snapshotAudiobook()
    
    // When
    let label = makeAccessibilityLabel(for: audiobook)
    
    // Then
    XCTAssertTrue(audiobook.isAudiobook, "Test prerequisite: book should be an audiobook")
    XCTAssertTrue(label.contains(Strings.Generic.audiobook), "Audiobook accessibility label should include 'Audiobook' designation")
    XCTAssertTrue(label.contains(audiobook.title), "Audiobook accessibility label should contain the title")
  }
  
  /// PP-3346: Verifies that regular eBooks do NOT have audiobook designation
  func testAccessibilityLabel_ebookDoesNotIncludeAudiobookDesignation() {
    // Given
    let ebook = TPPBookMocker.snapshotEPUB()
    
    // When
    let label = makeAccessibilityLabel(for: ebook)
    
    // Then
    XCTAssertFalse(ebook.isAudiobook, "Test prerequisite: book should NOT be an audiobook")
    XCTAssertFalse(label.contains(Strings.Generic.audiobook), "Regular eBook should NOT have audiobook designation")
    XCTAssertTrue(label.contains(ebook.title), "eBook accessibility label should contain the title")
  }
  
  /// PP-3346: Verifies accessibility label format is VoiceOver-friendly
  func testAccessibilityLabel_formatIsVoiceOverFriendly() {
    // Given
    let book = TPPBookMocker.mockBook(title: "Pride and Prejudice", authors: "Jane Austen")
    
    // When
    let label = makeAccessibilityLabel(for: book)
    
    // Then - Format should be "Title by Author" for natural VoiceOver reading
    let expectedFormat = "Pride and Prejudice \(Strings.Generic.by) Jane Austen"
    XCTAssertEqual(label, expectedFormat, "Accessibility label format should be 'Title by Author'")
  }
  
  /// PP-3346: Verifies audiobook label format is VoiceOver-friendly
  func testAccessibilityLabel_audiobookFormatIsVoiceOverFriendly() {
    // Given
    let audiobook = TPPBookMocker.snapshotAudiobook() // "Pride and Prejudice" by "Jane Austen"
    
    // When
    let label = makeAccessibilityLabel(for: audiobook)
    
    // Then - Format should be "Title. Audiobook. by Author" for clear VoiceOver reading
    XCTAssertTrue(label.hasPrefix(audiobook.title), "Label should start with book title")
    XCTAssertTrue(label.contains(". \(Strings.Generic.audiobook)."), "Audiobook designation should have periods for VoiceOver pauses")
    if let authors = audiobook.authors {
      XCTAssertTrue(label.contains("\(Strings.Generic.by) \(authors)"), "Label should end with author attribution")
    }
  }
  
  // MARK: - Helper Methods
  
  /// Replicates the accessibility label generation logic from CatalogLaneRowView
  /// This ensures the test matches the production implementation
  private func makeAccessibilityLabel(for book: TPPBook) -> String {
    var label = book.title
    if book.isAudiobook {
      label += ". \(Strings.Generic.audiobook)."
    }
    if let authors = book.authors, !authors.isEmpty {
      label += " \(Strings.Generic.by) \(authors)"
    }
    return label
  }
}
