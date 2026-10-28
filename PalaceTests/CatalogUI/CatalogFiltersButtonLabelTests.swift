//
//  CatalogFiltersButtonLabelTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class CatalogFiltersButtonLabelTests: XCTestCase {

    /// The label has to come from a key that is actually translated. A bare
    /// literal is looked up as a localization key, and nothing defines
    /// "APPLY FILTERS", so every language rendered the key itself (PP-5414).
    func testIdleLabel_isTheTranslatedShowResultsString() {
        XCTAssertEqual(CatalogFiltersButtonLabel.text(isApplying: false),
                       Strings.Catalog.showResults)
    }

    func testApplyingLabel_isTheTranslatedProgressString() {
        XCTAssertEqual(CatalogFiltersButtonLabel.text(isApplying: true),
                       Strings.Catalog.applyingFilters)
    }

    /// Names the two strings that used to be shown, so a revert to literals
    /// fails here rather than only in a non-English build.
    func testNeitherLabel_isAnUndefinedLiteralKey() {
        for isApplying in [true, false] {
            let label = CatalogFiltersButtonLabel.text(isApplying: isApplying)
            XCTAssertNotEqual(label, "APPLY FILTERS")
            XCTAssertNotEqual(label, "APPLYING...")
        }
    }

    /// The keys these accessors use must exist in every localization that ships
    /// one, otherwise the lookup falls back to the key and the patron reads
    /// English again.
    func testBothKeys_areTranslatedInEveryShippedLocalization() throws {
        for language in ["de", "es", "it", "fr"] {
            let path = try XCTUnwrap(
                Bundle(for: Self.self).path(forResource: language, ofType: "lproj")
                    ?? Bundle.main.path(forResource: language, ofType: "lproj"),
                "no \(language).lproj in either bundle"
            )
            let strings = try XCTUnwrap(
                NSDictionary(contentsOfFile: path + "/Localizable.strings") as? [String: String],
                "\(language).lproj/Localizable.strings is unreadable"
            )
            XCTAssertNotNil(strings["SHOW RESULTS"],
                            "\(language) is missing the filters button's key")
            XCTAssertNotNil(strings["Loading…"],
                            "\(language) is missing the in-flight key")
        }
    }
}
