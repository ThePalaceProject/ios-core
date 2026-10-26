//
//  ReaderBookmarkSubtitleTests.swift
//  PalaceTests
//
//  Two bookmarks saved in the same chapter were indistinguishable in the list:
//  the subtitle carried a short date with no seconds and a chapter percentage,
//  so two saves in the same minute rendered the same string (PP-5395).
//

import XCTest
@testable import Palace

final class ReaderBookmarkSubtitleTests: XCTestCase {

  private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
  }

  /// Two bookmarks a few seconds apart must not render the same subtitle.
  ///
  /// This is the patron-visible complaint. Saving two passages in one chapter
  /// takes well under a minute, and a minute-resolution timestamp collapses
  /// them.
  func test_twoBookmarksSecondsApart_doNotRenderTheSameSubtitle() {
    let first = TPPReaderBookmarkCell.subtitle(
      forDate: date("2026-10-26T14:03:05Z"),
      percentInChapter: "12",
      percentInBook: "4"
    )
    let second = TPPReaderBookmarkCell.subtitle(
      forDate: date("2026-10-26T14:03:41Z"),
      percentInChapter: "14",
      percentInBook: "4"
    )

    XCTAssertNotEqual(
      first, second,
      "two saves 36 seconds apart must be distinguishable; both read \(first)"
    )
  }

  /// Even at the same instant, two positions in a chapter differ.
  ///
  /// The timestamp cannot carry the whole job: a patron restoring a backup, or
  /// two bookmarks written by a sync in one batch, can share a time. Progress
  /// through the book is stored on every bookmark and is distinct per position,
  /// so the subtitle uses it too.
  func test_twoBookmarksAtTheSameInstant_stillDifferByPosition() {
    let when = date("2026-10-26T14:03:05Z")

    let earlier = TPPReaderBookmarkCell.subtitle(
      forDate: when, percentInChapter: "10", percentInBook: "31"
    )
    let later = TPPReaderBookmarkCell.subtitle(
      forDate: when, percentInChapter: "80", percentInBook: "34"
    )

    XCTAssertNotEqual(
      earlier, later,
      "two positions saved at one instant must still be distinguishable; both read \(earlier)"
    )
  }

  /// The subtitle says where in the book as well as where in the chapter.
  ///
  /// `progressWithinBook` is stored and populated on every bookmark and was not
  /// being shown. Without it a patron sees "48% through chapter" for two
  /// different chapters and has no sense of where either sits.
  func test_theSubtitle_reportsProgressThroughTheBookAsWellAsTheChapter() {
    let subtitle = TPPReaderBookmarkCell.subtitle(
      forDate: date("2026-10-26T14:03:05Z"),
      percentInChapter: "48",
      percentInBook: "12"
    )

    XCTAssertTrue(subtitle.contains("48"), "the chapter percentage must survive: \(subtitle)")
    XCTAssertTrue(subtitle.contains("12"), "progress through the book must appear: \(subtitle)")
  }

  /// A bookmark with no book progress still renders a usable subtitle.
  ///
  /// Anything that arrived from the server or another device can be missing
  /// fields, so the row degrades rather than showing a stray separator or an
  /// empty percentage.
  func test_whenBookProgressIsMissing_theSubtitleOmitsItRatherThanShowingAGap() {
    let subtitle = TPPReaderBookmarkCell.subtitle(
      forDate: date("2026-10-26T14:03:05Z"),
      percentInChapter: "48",
      percentInBook: nil
    )

    XCTAssertTrue(subtitle.contains("48"), "the chapter percentage must still show: \(subtitle)")
    XCTAssertFalse(subtitle.hasSuffix("-"), "a missing field must not leave a dangling separator: \(subtitle)")
    XCTAssertFalse(subtitle.contains("  "), "a missing field must not leave a double space: \(subtitle)")
  }

  /// An unparseable timestamp must not blank the whole subtitle.
  ///
  /// `prettyDate` returns an empty string for a date it cannot read, which
  /// previously produced a subtitle starting with " - ".
  func test_whenTheDateIsMissing_theSubtitleStillCarriesThePositions() {
    let subtitle = TPPReaderBookmarkCell.subtitle(
      forDate: nil,
      percentInChapter: "48",
      percentInBook: "12"
    )

    XCTAssertTrue(subtitle.contains("48"), "positions must survive a bad date: \(subtitle)")
    XCTAssertFalse(subtitle.hasPrefix("-"), "a missing date must not leave a leading separator: \(subtitle)")
    XCTAssertFalse(subtitle.hasPrefix(" "), "a missing date must not leave leading space: \(subtitle)")
  }
}
