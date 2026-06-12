//
//  FindawaySavedVsPlayedTests.swift
//  PalaceTests
//
//  App-side end-to-end for the 3.2.0 Findaway dual chapter-numbering regression
//  ("Dune", Findaway id 32884). Device log: saved key findaway:1:4 while the engine
//  played (1,3); "Part 1 Chapter 2/3/4" all resolved onto physical file 1:3. With
//  the toolkit's TOC collapse, the chapter SHOWN == the chapter SAVED == the played
//  track, so a saved bookmark round-trips back to the file it was taken on.
//
//  GREEN-ONLY (by construction): this asserts the POST-FIX invariant
//  (saved == played) rather than red-firsting the bug at the app layer. The
//  collapse that produces the invariant lives in the ios-audiobooktoolkit submodule
//  (already bumped to the fix here), so an app-layer red-first would require
//  reverting the submodule. The BUG DIRECTION -- pre-fix the uncollapsed list
//  resolved several chapters onto one physical key, so saved 1:4 != played 1:3 -- is
//  proven red-first in the toolkit suite (FindawayOversubdividedTOCTests: toc 5->3,
//  three indices on findaway:1:3). This app test is the consumer-side smoke that the
//  invariant holds through toAudioBookmark + the position round-trip.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

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
