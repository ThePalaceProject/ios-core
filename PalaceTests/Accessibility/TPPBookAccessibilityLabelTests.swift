//
//  TPPBookAccessibilityLabelTests.swift
//  PalaceTests
//
//  Direct unit tests for TPPBook.voiceOverLabel — the single source of truth
//  for the VoiceOver label of any book cell (catalog lanes, My Books, Holds).
//  Catalog lane tests exercise this transitively, but this file pins the
//  contract so future cell views can rely on it without re-discovering the
//  format.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class TPPBookAccessibilityLabelTests: XCTestCase {

  // MARK: - Ebook

  func testVoiceOverLabel_ebook_titleByAuthor() {
    let book = TPPBookMocker.mockBook(title: "The Great Gatsby", authors: "F. Scott Fitzgerald")
    XCTAssertFalse(book.isAudiobook, "Test prerequisite: book should not be an audiobook")
    XCTAssertEqual(book.voiceOverLabel, "The Great Gatsby, by F. Scott Fitzgerald")
  }

  func testVoiceOverLabel_ebook_noAuthor_titleOnly() {
    let book = TPPBookMocker.mockBook(title: "Untitled Work", authors: nil)
    XCTAssertEqual(book.voiceOverLabel, "Untitled Work")
  }

  func testVoiceOverLabel_ebook_blankAuthor_titleOnly() {
    let book = TPPBookMocker.mockBook(title: "Untitled Work", authors: "   ")
    XCTAssertEqual(
      book.voiceOverLabel, "Untitled Work",
      "Whitespace-only author strings must be treated as no author"
    )
  }

  // MARK: - Audiobook

  /// `snapshotAudiobook()` provides an audiobook with author "Jane Austen"
  /// and no narrator (contributors are empty), so the label must include
  /// "audiobook" plus the author.
  func testVoiceOverLabel_audiobook_authorOnly_includesFormatAndAuthor() {
    let audiobook = TPPBookMocker.snapshotAudiobook()
    XCTAssertTrue(audiobook.isAudiobook, "Test prerequisite: book should be an audiobook")
    XCTAssertEqual(audiobook.voiceOverLabel, "Pride and Prejudice, audiobook, by Jane Austen")
  }

  func testVoiceOverLabel_audiobook_withNarrator_includesNarrator() {
    let audiobook = makeAudiobook(
      title: "Project Hail Mary",
      author: "Andy Weir",
      narrator: "Ray Porter"
    )
    XCTAssertEqual(
      audiobook.voiceOverLabel,
      "Project Hail Mary, by Andy Weir, narrated by Ray Porter"
    )
  }

  func testVoiceOverLabel_audiobook_narratorOnly_omitsAuthorPhrase() {
    let audiobook = makeAudiobook(
      title: "Anonymous Tales",
      author: nil,
      narrator: "Stephen Fry"
    )
    XCTAssertEqual(audiobook.voiceOverLabel, "Anonymous Tales, narrated by Stephen Fry")
  }

  func testVoiceOverLabel_audiobook_neitherAuthorNorNarrator_titlePlusFormat() {
    let audiobook = makeAudiobook(title: "Mystery Audio", author: nil, narrator: nil)
    XCTAssertTrue(audiobook.voiceOverLabel.hasPrefix("Mystery Audio, "))
    XCTAssertTrue(audiobook.voiceOverLabel.contains(Strings.Generic.audiobook))
  }

  // MARK: - Negative space

  func testVoiceOverLabel_neverIncludesSummary() {
    let book = TPPBookMocker.mockBook(title: "Test Title", authors: "Test Author")
    XCTAssertNotNil(book.summary)
    XCTAssertFalse(
      book.voiceOverLabel.contains(book.summary ?? "<missing>"),
      "voiceOverLabel must never leak the book summary into VoiceOver"
    )
  }

  // MARK: - Helpers

  /// Builds an audiobook with optional narrator support. The standard
  /// TPPBookMocker helpers do not expose `contributors`, so this constructs a
  /// `TPPBook` directly using the same initializer pattern as
  /// `TPPBookMocker.createSnapshotBook`.
  private func makeAudiobook(title: String, author: String?, narrator: String?) -> TPPBook {
    let identifier = "test-audiobook-\(UUID().uuidString)"
    let acquisitionURL = URL(string: "https://example.com/\(identifier)")!

    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: DistributorType.OpenAccessAudiobook.rawValue,
      hrefURL: acquisitionURL,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let authorList: [TPPBookAuthor]
    if let author = author {
      authorList = [TPPBookAuthor(authorName: author, relatedBooksURL: nil)]
    } else {
      authorList = []
    }

    var contributors: [String: Any] = [:]
    if let narrator = narrator {
      contributors["nrt"] = [narrator]
    }

    return TPPBook(
      acquisitions: [acquisition],
      authors: authorList,
      categoryStrings: ["Fiction"],
      distributor: "Test",
      identifier: identifier,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "Test Publisher",
      subtitle: nil,
      summary: "Test summary",
      title: title,
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
      contributors: contributors,
      bookDuration: "12:00:00",
      imageCache: MockImageCache()
    )
  }
}
