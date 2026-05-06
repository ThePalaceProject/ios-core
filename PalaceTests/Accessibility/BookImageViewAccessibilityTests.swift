//
//  BookImageViewAccessibilityTests.swift
//  PalaceTests
//
//  Regression tests for PP-3969: VoiceOver focus on book detail cover image
//  must land on the cover (not the small audiobook badge overlay). The cover
//  ZStack is a single accessibility element whose label always begins with
//  "Cover image for <title>" so VoiceOver announces the cover first and the
//  badge can never become an independent focus target.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

final class BookImageViewAccessibilityTests: XCTestCase {

  // MARK: - Combined accessibility label

  /// An eBook's cover label is just "Cover image for <title>" — no audiobook suffix.
  func testCombinedAccessibilityLabel_ebook_isCoverImageForTitle() {
    let ebook = TPPBookMocker.snapshotEPUB()
    let view = BookImageView(book: ebook)

    XCTAssertFalse(ebook.isAudiobook, "Test prerequisite: book should not be an audiobook")
    XCTAssertEqual(view.combinedAccessibilityLabel, "Cover image for \(ebook.title)")
  }

  /// An audiobook's cover label leads with "Cover image for <title>" and appends ", Audiobook".
  /// This guarantees VoiceOver announces the cover identity *before* the badge information.
  func testCombinedAccessibilityLabel_audiobook_startsWithCoverThenAppendsAudiobook() {
    let audiobook = TPPBookMocker.snapshotAudiobook()
    let view = BookImageView(book: audiobook)

    XCTAssertTrue(audiobook.isAudiobook, "Test prerequisite: book should be an audiobook")

    let label = view.combinedAccessibilityLabel
    XCTAssertTrue(
      label.hasPrefix("Cover image for \(audiobook.title)"),
      "Cover label must lead with cover identity, got: \(label)"
    )
    XCTAssertTrue(label.contains("Audiobook"), "Audiobook badge info must still be announced")
  }

  /// The cover identity must come *before* the audiobook designation in the combined label,
  /// so VoiceOver users hear the cover first — directly addressing PP-3969.
  func testCombinedAccessibilityLabel_audiobook_coverPrecedesBadge() {
    let audiobook = TPPBookMocker.snapshotAudiobook()
    let view = BookImageView(book: audiobook)

    let label = view.combinedAccessibilityLabel
    let coverRange = label.range(of: "Cover image for")
    let audiobookRange = label.range(of: "Audiobook")

    XCTAssertNotNil(coverRange)
    XCTAssertNotNil(audiobookRange)
    if let c = coverRange, let a = audiobookRange {
      XCTAssertLessThan(
        c.lowerBound, a.lowerBound,
        "'Cover image for ...' must precede 'Audiobook' so VoiceOver focuses on the cover first"
      )
    }
  }
}
