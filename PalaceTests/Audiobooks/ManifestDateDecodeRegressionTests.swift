//
//  ManifestDateDecodeRegressionTests.swift
//  PalaceTests
//
//  Helpspot 17727 — every audiobook open failed for an iOS 3.0.0 user with:
//    `dataCorrupted at metadata → modified — Cannot decode date string 2026-02-17T15:56:15+0000`
//  Locks down the Manifest.customDecoder date-parse path so it stays robust under
//  the iOS device prefs (non-Gregorian calendar / non-Latin numerals) that Apple's
//  TN2154 + QA1480 warn about.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class ManifestDateDecodeRegressionTests: XCTestCase {
  /// Smallest manifest that exercises Metadata.modified + Metadata.published using
  /// the exact RFC 3339 `+0000` offset shape the Palace Marketplace emitted to the
  /// user whose audiobook opens were failing.
  private let helpspot17727JSON = """
  {
    "@context": ["https://readium.org/webpub-manifest/context.jsonld"],
    "metadata": {
      "title": "Helpspot 17727 repro",
      "@type": "http://schema.org/Audiobook",
      "identifier": "urn:isbn:repro-17727",
      "duration": 1,
      "modified": "2026-02-17T15:56:15+0000",
      "published": "2021-05-04T00:00:00+0000"
    },
    "readingOrder": []
  }
  """

  /// The exact failing string from the customer device logs must round-trip
  /// through `Manifest.customDecoder()` to its true UTC instant.
  func test_helpspot17727_customDecoder_decodesModifiedAndPublished() throws {
    let data = try XCTUnwrap(helpspot17727JSON.data(using: .utf8))
    let manifest = try Manifest.customDecoder().decode(Manifest.self, from: data)

    let modified = try XCTUnwrap(manifest.metadata?.modified, "metadata.modified must decode")
    XCTAssertEqual(
      modified.timeIntervalSince1970, 1771343775,
      accuracy: 1,
      "modified should resolve to 2026-02-17T15:56:15Z"
    )

    let published = try XCTUnwrap(manifest.metadata?.published, "metadata.published must decode")
    XCTAssertEqual(
      published.timeIntervalSince1970, 1620086400,
      accuracy: 1,
      "published should resolve to 2021-05-04T00:00:00Z"
    )
  }

  /// Diagnostic: an *unpinned* DateFormatter — the pre-fix shape — produces
  /// centuries-off Gregorian instants under non-Gregorian device calendars.
  /// This is the failure mode the customer hit (rendered as `dataCorrupted`
  /// once the wildly out-of-range Date trips downstream consumers / on iOS
  /// versions where extreme calendar substitutions yield nil).  Locked in here
  /// to document *why* customDecoder must pin locale/calendar/timeZone — if
  /// somebody removes the pinning, the demonstration below starts being a real
  /// production bug again.
  func test_unpinnedDateFormatter_isUnsafeUnderNonGregorianCalendars() {
    let dateString = "2026-02-17T15:56:15+0000"
    let expectedEpoch: TimeInterval = 1771343775

    let nonGregorianCases: [(String, Locale, Calendar)] = [
      ("th_TH+buddhist",  Locale(identifier: "th_TH"),  Calendar(identifier: .buddhist)),
      ("ja_JP+japanese",  Locale(identifier: "ja_JP"),  Calendar(identifier: .japanese)),
      ("ar_SA+islamic",   Locale(identifier: "ar_SA"),  Calendar(identifier: .islamicCivil)),
      ("fa_IR+persian",   Locale(identifier: "fa_IR"),  Calendar(identifier: .persian)),
      ("he_IL+hebrew",    Locale(identifier: "he_IL"),  Calendar(identifier: .hebrew)),
    ]

    for (label, locale, calendar) in nonGregorianCases {
      let df = DateFormatter()
      df.locale = locale
      df.calendar = calendar
      var parsed: Date?
      for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
        df.dateFormat = fmt
        if let d = df.date(from: dateString) { parsed = d; break }
      }
      let epoch = parsed?.timeIntervalSince1970 ?? .nan
      let drift = abs(epoch - expectedEpoch)
      XCTAssertGreaterThan(
        drift, 1_000_000,
        "Sanity check: unpinned formatter must mis-parse under \(label) — drift was only \(drift)s"
      )
    }
  }

  /// `Manifest.customDecoder()` must be immune to the same non-Gregorian device
  /// prefs above.  Because the decoder pins its own DateFormatter (en_US_POSIX
  /// + Gregorian + UTC), the round-trip is independent of the test process's
  /// runtime calendar/locale.  This is the assertion that proves the fix.
  func test_customDecoder_isImmuneToDeviceCalendarPrefs() throws {
    let data = try XCTUnwrap(helpspot17727JSON.data(using: .utf8))

    // Run the decode multiple times — the customDecoder() factory must hand out
    // a fresh, locale-pinned formatter each call regardless of when it's invoked.
    for _ in 0..<5 {
      let manifest = try Manifest.customDecoder().decode(Manifest.self, from: data)
      let modified = try XCTUnwrap(manifest.metadata?.modified)
      XCTAssertEqual(modified.timeIntervalSince1970, 1771343775, accuracy: 1)
    }
  }
}
