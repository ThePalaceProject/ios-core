//
//  ManagedLibraryTestingGuideTests.swift
//  PalaceTests
//
//  PP-5070 — the in-app guide documents a payload someone will copy into an
//  MDM. These tests exist because documentation drift is silent: the guide
//  keeps rendering, the administrator keeps copying, and nothing configures.
//
//  So the guide's own example is fed to the real parser. If the schema moves
//  and the example does not, this suite fails rather than the school.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ManagedLibraryTestingGuideTests: XCTestCase {

    // MARK: - The documented example must actually work

    func testDocumentedExample_ParsesIntoAUsableConfiguration() {
        let result = ManagedAppConfiguration.parse(
            managedDictionary: ManagedLibraryTestingGuide.exampleConfiguration
        )
        XCTAssertNotNil(result.configuration, "the example an administrator copies must parse")
        XCTAssertEqual(result.warnings, [], "and must parse cleanly: \(result.warnings)")
    }

    func testDocumentedExample_SelectsOneLibraryAndAddsTheOther() {
        let parsed = ManagedAppConfiguration.libraryPreconfiguration(
            managedDictionary: ManagedLibraryTestingGuide.exampleConfiguration
        )
        XCTAssertEqual(parsed?.libraryId, ManagedLibraryTestingGuide.placeholderSelected)
        XCTAssertEqual(parsed?.additionalLibraryIds, [ManagedLibraryTestingGuide.placeholderAdditional])
    }

    func testRenderedXML_IsGeneratedFromTheSameValueTheParserReads() {
        // The displayed payload and the parsed payload are one value rendered
        // two ways. If that ever stops being true, the guide can show something
        // the app would reject.
        let xml = ManagedLibraryTestingGuide.examplePayloadXML
        guard let data = xml.data(using: .utf8),
              let round = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else {
            return XCTFail("the guide's rendered payload is not a readable plist")
        }

        let result = ManagedAppConfiguration.parse(managedDictionary: round)
        XCTAssertEqual(result.configuration?.libraryId, ManagedLibraryTestingGuide.placeholderSelected)
        XCTAssertEqual(result.warnings, [])
    }

    // MARK: - The guide must name the keys the parser reads

    func testGuide_NamesEveryKeyTheParserAccepts() {
        // A guide that documents a key the parser does not read sends an
        // administrator to type something inert.
        let prose = ManagedLibraryTestingGuide.sections
            .flatMap(\.paragraphs)
            .joined(separator: "\n")

        for key in [ManagedAppConfiguration.Key.libraryId,
                    ManagedAppConfiguration.Key.libraryCatalogURL,
                    ManagedAppConfiguration.Key.additionalLibraryIds] {
            XCTAssertTrue(prose.contains(key), "guide never mentions '\(key)'")
        }
    }

    func testGuide_NamesTheUserDefaultsKeyAnMDMWritesTo() {
        let prose = ManagedLibraryTestingGuide.sections
            .flatMap(\.paragraphs)
            .joined(separator: "\n")
        XCTAssertTrue(prose.contains(ManagedAppConfiguration.userDefaultsKey))
    }

    // MARK: - Placeholders, not a partner's real libraries

    func testPlaceholders_AreValidIdentifiersSoTheExampleIsCopyable() {
        // They must survive the same normalization a real one does, or the
        // example teaches the wrong shape.
        for placeholder in [ManagedLibraryTestingGuide.placeholderSelected,
                            ManagedLibraryTestingGuide.placeholderAdditional] {
            XCTAssertEqual(
                ManagedAppConfiguration.canonicalLibraryId(placeholder),
                placeholder,
                "placeholder is not already in canonical form: \(placeholder)"
            )
        }
    }

    func testPlaceholders_AreDistinctSoTheExampleShowsTwoLibraries() {
        XCTAssertNotEqual(ManagedLibraryTestingGuide.placeholderSelected,
                          ManagedLibraryTestingGuide.placeholderAdditional)
    }

    // MARK: - Shape

    func testSections_AreNonEmptyAndEachCarriesContent() {
        let sections = ManagedLibraryTestingGuide.sections
        XCTAssertFalse(sections.isEmpty)
        for section in sections {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.paragraphs.isEmpty, "section '\(section.title)' has no body")
            XCTAssertFalse(section.paragraphs.contains { $0.isEmpty },
                           "section '\(section.title)' has an empty paragraph")
        }
    }

    func testSectionIdentifiers_AreUniqueSoTheListRendersCorrectly() {
        let ids = ManagedLibraryTestingGuide.sections.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate section ids: \(ids)")
    }
}
