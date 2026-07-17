//
//  TPPPDFLocationTests.swift
//  PalaceTests
//
//  Tests for TPPPDFLocation model and its Identifiable conformance.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class TPPPDFLocationTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit_AllParameters_SetsProperties() {
        let location = TPPPDFLocation(
            title: "Chapter 1",
            subtitle: "Introduction",
            pageLabel: "i",
            pageNumber: 1,
            level: 2
        )

        XCTAssertEqual(location.title, "Chapter 1")
        XCTAssertEqual(location.subtitle, "Introduction")
        XCTAssertEqual(location.pageLabel, "i")
        XCTAssertEqual(location.pageNumber, 1)
        XCTAssertEqual(location.level, 2)
    }

    func testInit_NilOptionals_DefaultsLevelToZero() {
        let location = TPPPDFLocation(
            title: nil,
            subtitle: nil,
            pageLabel: nil,
            pageNumber: 5
        )

        XCTAssertNil(location.title)
        XCTAssertNil(location.subtitle)
        XCTAssertNil(location.pageLabel)
        XCTAssertEqual(location.pageNumber, 5)
        XCTAssertEqual(location.level, 0)
    }

    // MARK: - Identifiable Tests

    /// SRS: PDF-004 — Page navigation updates position
    func testId_UniqueForDifferentPages() {
        let loc1 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 1)
        let loc2 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 2)

        XCTAssertNotEqual(loc1.id, loc2.id)
        // The page number must appear in the ID so navigation can be distinguished
        XCTAssertTrue(loc1.id.contains("1"), "Page 1 ID must contain '1'")
        XCTAssertTrue(loc2.id.contains("2"), "Page 2 ID must contain '2'")
    }

    func testId_UniqueForDifferentTitles() {
        let loc1 = TPPPDFLocation(title: "Chapter 1", subtitle: nil, pageLabel: nil, pageNumber: 1)
        let loc2 = TPPPDFLocation(title: "Chapter 2", subtitle: nil, pageLabel: nil, pageNumber: 1)

        XCTAssertNotEqual(loc1.id, loc2.id)
        // IDs must be stable: creating the same location again must produce the same ID
        let loc1Again = TPPPDFLocation(title: "Chapter 1", subtitle: nil, pageLabel: nil, pageNumber: 1)
        XCTAssertEqual(loc1.id, loc1Again.id, "Identical locations must produce identical IDs")
    }

    func testId_UniqueForDifferentLevels() {
        let loc1 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 1, level: 0)
        let loc2 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 1, level: 1)

        XCTAssertNotEqual(loc1.id, loc2.id)
        // The level encodes nesting depth — ID uniqueness spans all levels, not just 0 vs 1
        let loc3 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 1, level: 2)
        XCTAssertNotEqual(loc1.id, loc3.id, "Level-0 and level-2 must have distinct IDs")
        XCTAssertNotEqual(loc2.id, loc3.id, "Level-1 and level-2 must have distinct IDs")
    }

    func testId_SameForIdenticalLocations() {
        let loc1 = TPPPDFLocation(title: "X", subtitle: "Y", pageLabel: "1", pageNumber: 5, level: 2)
        let loc2 = TPPPDFLocation(title: "X", subtitle: "Y", pageLabel: "1", pageNumber: 5, level: 2)

        XCTAssertEqual(loc1.id, loc2.id)
        // Must be symmetric: loc2 == loc1 id is already verified above; also verify the ID is non-empty
        XCTAssertFalse(loc1.id.isEmpty, "Location ID must never be empty")
    }

    func testId_ContainsPageNumber() {
        let location = TPPPDFLocation(title: nil, subtitle: nil, pageLabel: nil, pageNumber: 42)

        XCTAssertTrue(location.id.contains("42"))
        // A different page number must produce an ID that contains its own page number
        let other = TPPPDFLocation(title: nil, subtitle: nil, pageLabel: nil, pageNumber: 99)
        XCTAssertTrue(other.id.contains("99"), "ID must embed the page number for navigation purposes")
        XCTAssertFalse(other.id.contains("42"), "ID must not embed the wrong page number")
    }

    func testId_HandlesNilValues_WithEmptyStrings() {
        let location = TPPPDFLocation(title: nil, subtitle: nil, pageLabel: nil, pageNumber: 0)
        // Format: "\(pageNumber)-\(pv)-\(s)-\(t)-\(level)"
        XCTAssertEqual(location.id, "0----0")
        // The ID must be non-empty even when all text fields are nil
        XCTAssertFalse(location.id.isEmpty)
    }

    func testId_UniqueForDifferentSubtitles() {
        let loc1 = TPPPDFLocation(title: "A", subtitle: "Sub1", pageLabel: nil, pageNumber: 1)
        let loc2 = TPPPDFLocation(title: "A", subtitle: "Sub2", pageLabel: nil, pageNumber: 1)

        XCTAssertNotEqual(loc1.id, loc2.id)
        // A location without a subtitle must also differ from one with a subtitle
        let loc3 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 1)
        XCTAssertNotEqual(loc1.id, loc3.id, "subtitle-present and subtitle-nil must differ")
    }

    func testId_UniqueForDifferentPageLabels() {
        let loc1 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: "i", pageNumber: 1)
        let loc2 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: "ii", pageNumber: 1)

        XCTAssertNotEqual(loc1.id, loc2.id)
        // A nil pageLabel must also differ from a non-nil one
        let loc3 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 1)
        XCTAssertNotEqual(loc1.id, loc3.id, "pageLabel 'i' vs nil must produce distinct IDs")
    }
}
