//
//  EntryPointFacetLocalizationTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// The format selector above the catalog shows the circulation manager's own
/// facet titles.
///
/// Observed on an iPad in German: the chrome around it reads Katalog, Meine
/// Bücher, Vormerkungen, Einstellungen, while the selector itself reads
/// All / Ebooks / Audiobooks. Those three are not app strings — none of them
/// appears in any `.lproj` — they are OPDS facet titles in the `Formats`
/// group, which `extractOPDS2Facets` renders verbatim. The server sends
/// English because the app sets `Accept-Language` to the empty string on every
/// request, and that is deliberate: populating it would re-introduce the
/// language-based catalog filtering the project wants dropped.
///
/// So the label is localized on this side, keyed on the href's `entrypoint`
/// value rather than on the server's wording. The value is a stable token
/// (`All`, `Book`, `Audio`); the title is display text the CM may reword or
/// one day localize itself.
@MainActor
final class EntryPointFacetLocalizationTests: XCTestCase {

  private func facet(_ query: String, title: String) -> (URL, String) {
    (URL(string: "https://example.org/feed/1?\(query)")!, title)
  }

  // MARK: - The three the circulation manager actually sends

  func testKnownEntryPointsAreLocalized() {
    let cases = [
      ("entrypoint=All",   "All",        "All"),
      ("entrypoint=Book",  "Ebooks",     "Ebooks"),
      ("entrypoint=Audio", "Audiobooks", "Audiobooks"),
    ]
    for (query, serverTitle, expectedEnglish) in cases {
      let (url, title) = facet(query, title: serverTitle)
      XCTAssertEqual(
        CatalogViewModel.localizedEntryPointTitle(href: url, serverTitle: title),
        expectedEnglish,
        "\(query) should resolve through the app's own strings"
      )
    }
  }

  // MARK: - The key is the href value, not the server's wording

  func testTheServerWordingDoesNotDecideTheLabel() {
    // Same entrypoint, different display text: the CM rewording its facet must
    // not silently fall back to raw English.
    let (url, _) = facet("entrypoint=Audio", title: "Spoken Word")
    XCTAssertEqual(
      CatalogViewModel.localizedEntryPointTitle(href: url, serverTitle: "Spoken Word"),
      "Audiobooks"
    )
  }

  func testTheValueIsMatchedWithoutCaseSensitivity() {
    for v in ["audio", "AUDIO", "Audio"] {
      let (url, _) = facet("entrypoint=\(v)", title: "x")
      XCTAssertEqual(
        CatalogViewModel.localizedEntryPointTitle(href: url, serverTitle: "x"),
        "Audiobooks", "entrypoint=\(v)"
      )
    }
  }

  // MARK: - Anything unrecognised keeps the server's own words

  func testAnUnknownEntryPointKeepsTheServerTitle() {
    // A CM that adds a format we have no string for must still show its label,
    // not a blank chip and not a wrong one.
    let (url, _) = facet("entrypoint=Video", title: "Videos")
    XCTAssertEqual(
      CatalogViewModel.localizedEntryPointTitle(href: url, serverTitle: "Videos"),
      "Videos"
    )
  }

  func testAFacetWithNoEntryPointParameterKeepsItsTitle() {
    let (url, _) = facet("available=all", title: "Available Now")
    XCTAssertEqual(
      CatalogViewModel.localizedEntryPointTitle(href: url, serverTitle: "Available Now"),
      "Available Now"
    )
  }

  func testAnEmptyEntryPointValueKeepsTheServerTitle() {
    // The A1QA feed contains a bare `entrypoint=` among its links.
    let (url, _) = facet("entrypoint=", title: "Everything")
    XCTAssertEqual(
      CatalogViewModel.localizedEntryPointTitle(href: url, serverTitle: "Everything"),
      "Everything"
    )
  }

  // MARK: - Every shipped language carries the three keys

  func testEveryShippedLanguageTranslatesTheThreeLabels() {
    // English ships no table: its keys are the English text. The other four
    // must each define all three, or a German catalog keeps an English chip —
    // which is the defect this fixes, reappearing one language at a time.
    let keys = ["All", "Ebooks", "Audiobooks"]
    // The APP bundle, resolved through a type that ships in it. An earlier
    // version used Bundle(for: Self.self) — the TEST bundle, which carries no
    // .lproj — and skipped every language through a `continue`, so deleting a
    // German key left the test green. A missing bundle is a failure here, not
    // a skip, because a skip is what made it vacuous.
    let appBundle = Bundle(for: CatalogViewModel.self)
    for code in ["de", "es", "fr", "it"] {
      guard let path = appBundle.path(forResource: code, ofType: "lproj"),
            let bundle = Bundle(path: path)
      else {
        XCTFail("\(code).lproj is not in the app bundle, so this test can assert nothing")
        continue
      }
      for key in keys {
        let value = bundle.localizedString(forKey: key, value: "__missing__", table: nil)
        XCTAssertNotEqual(value, "__missing__", "\(code).lproj is missing \"\(key)\"")
        XCTAssertFalse(value.isEmpty, "\(code).lproj has an empty value for \"\(key)\"")
      }
    }
  }
}
