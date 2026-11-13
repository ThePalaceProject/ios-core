//
//  FindawaySavedVsPlayedTests.swift
//
//  App-side check for the 3.2.0 Findaway dual chapter-numbering regression
//  ("Dune", Findaway id 32884): the engine played 1:3 while findaway:1:4 was
//  saved. With the toolkit's TOC collapse, shown == saved == played. Asserts
//  the post-fix invariant only; the red-first proof lives in the toolkit's
//  FindawayOversubdividedTOCTests, since reproducing the bug here would mean
//  reverting the submodule.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class FindawaySavedVsPlayedTests: XCTestCase {
  private let testID = "DuneSavedVsPlayed"
  private let playedKey = "urn:org.thepalaceproject:findaway:1:3"

  private func loadDune() throws -> (AudiobookTableOfContents, Tracks) {
    let manifest = try Manifest.from(
      jsonFileName: "dune_oversubdivided_manifest",
      bundle: Bundle(for: type(of: self)))
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    return (AudiobookTableOfContents(manifest: manifest, tracks: tracks), tracks)
  }

  /// SAVED == PLAYED: a TrackPosition physically on the oversubdivided file
  /// (findaway:1:3 @34.757) must save to that SAME played track — not a neighbor
  /// (the device log's saved 1:4 ≠ played 1:3) — and round-trip back to it.
  func testDuneOversubdivided_savedBookmarkKeyEqualsPlayedTrack() throws {
    let (toc, tracks) = try loadDune()
    guard let played = tracks.track(forKey: playedKey) else {
      return XCTFail("fixture must contain physical track \(playedKey)")
    }
    let position = TrackPosition(track: played, timestamp: 34.757, tracks: tracks)

    // The saved bookmark records the PLAYED track's key (not 1:4).
    let bookmark = position.toAudioBookmark()
    XCTAssertEqual(
      bookmark.readingOrderItem, playedKey,
      "Saved bookmark key must equal the played track \(playedKey); device log showed saved 1:4 ≠ played 1:3.")

    // Round-trip: restoring the bookmark lands back on the SAME physical track.
    let restored = TrackPosition(audioBookmark: bookmark, toc: toc.toc, tracks: tracks)
    XCTAssertEqual(
      restored?.track.key, playedKey,
      "Restored position must resolve to the played track (saved == played).")

    // The chapter SHOWN for that position is the single collapsed chapter on 1:3.
    let shown = try toc.chapter(forPosition: position)
    XCTAssertEqual(shown.position.track.key, playedKey, "Shown/saved chapter must be on the played track.")
    XCTAssertEqual(
      toc.toc.filter { $0.position.track.key == playedKey }.count, 1,
      "Exactly one collapsed chapter backs the played file (no dual numbering).")
  }
}
