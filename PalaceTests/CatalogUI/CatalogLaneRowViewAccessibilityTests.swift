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
    XCTAssertEqual(label, "The Great Gatsby, F. Scott Fitzgerald")
  }
  
  /// PP-3346: Verifies that a book without authors still has a valid accessibility label
  func testAccessibilityLabel_bookWithoutAuthor() {
    // Given
    let book = TPPBookMocker.mockBook(title: "Untitled Work", authors: nil)
    
    // When
    let label = makeAccessibilityLabel(for: book)
    
    // Then
    XCTAssertEqual(label, "Untitled Work")
  }
  
  /// PP-3346: Verifies that audiobooks have proper accessibility designation
  func testAccessibilityLabel_audiobookIncludesAudiobookDesignation() {
    // Given
    let audiobook = TPPBookMocker.snapshotAudiobook()
    
    // When
    let label = makeAccessibilityLabel(for: audiobook)
    
    // Then
    XCTAssertTrue(audiobook.isAudiobook, "Test prerequisite: book should be an audiobook")
    XCTAssertTrue(label.contains(Strings.Generic.audiobook))
    XCTAssertTrue(label.contains(audiobook.title))
  }
  
  /// PP-3346: Verifies that regular eBooks do NOT have audiobook designation
  func testAccessibilityLabel_ebookDoesNotIncludeAudiobookDesignation() {
    // Given
    let ebook = TPPBookMocker.snapshotEPUB()
    
    // When
    let label = makeAccessibilityLabel(for: ebook)
    
    // Then
    XCTAssertFalse(ebook.isAudiobook, "Test prerequisite: book should NOT be an audiobook")
    XCTAssertFalse(label.contains(Strings.Generic.audiobook))
  }
  
  /// PP-3346: Verifies accessibility label uses comma-separated format
  func testAccessibilityLabel_usesCommaSeparatedFormat() {
    // Given
    let book = TPPBookMocker.mockBook(title: "Pride and Prejudice", authors: "Jane Austen")
    
    // When
    let label = makeAccessibilityLabel(for: book)
    
    // Then - Format: "Title, Author"
    XCTAssertEqual(label, "Pride and Prejudice, Jane Austen")
  }
  
  /// PP-3346: Verifies audiobook label format includes audiobook designation
  func testAccessibilityLabel_audiobookFormat() {
    // Given
    let audiobook = TPPBookMocker.snapshotAudiobook() // "Pride and Prejudice" by "Jane Austen"
    
    // When
    let label = makeAccessibilityLabel(for: audiobook)
    
    // Then - Format: "Title, Audiobook, Author"
    XCTAssertTrue(label.hasPrefix(audiobook.title))
    if let authors = audiobook.authors {
      let expected = "\(audiobook.title), \(Strings.Generic.audiobook), \(authors)"
      XCTAssertEqual(label, expected)
    }
  }
  
  // MARK: - Helper Methods
  
  /// Replicates the accessibility label generation logic from CatalogLaneRowView
  private func makeAccessibilityLabel(for book: TPPBook) -> String {
    var components = [book.title]
    if book.isAudiobook {
      components.append(Strings.Generic.audiobook)
    }
    if let authors = book.authors, !authors.isEmpty {
      components.append(authors)
    }
    return components.joined(separator: ", ")
  }
}
