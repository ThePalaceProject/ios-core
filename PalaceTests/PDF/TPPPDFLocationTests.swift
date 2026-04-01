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
    }

    func testId_UniqueForDifferentTitles() {
        let loc1 = TPPPDFLocation(title: "Chapter 1", subtitle: nil, pageLabel: nil, pageNumber: 1)
        let loc2 = TPPPDFLocation(title: "Chapter 2", subtitle: nil, pageLabel: nil, pageNumber: 1)

        XCTAssertNotEqual(loc1.id, loc2.id)
    }

    func testId_UniqueForDifferentLevels() {
        let loc1 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 1, level: 0)
        let loc2 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: nil, pageNumber: 1, level: 1)

        XCTAssertNotEqual(loc1.id, loc2.id)
    }

    func testId_SameForIdenticalLocations() {
        let loc1 = TPPPDFLocation(title: "X", subtitle: "Y", pageLabel: "1", pageNumber: 5, level: 2)
        let loc2 = TPPPDFLocation(title: "X", subtitle: "Y", pageLabel: "1", pageNumber: 5, level: 2)

        XCTAssertEqual(loc1.id, loc2.id)
    }

    func testId_ContainsPageNumber() {
        let location = TPPPDFLocation(title: nil, subtitle: nil, pageLabel: nil, pageNumber: 42)

        XCTAssertTrue(location.id.contains("42"))
    }

    func testId_HandlesNilValues_WithEmptyStrings() {
        let location = TPPPDFLocation(title: nil, subtitle: nil, pageLabel: nil, pageNumber: 0)
        // Format: "\(pageNumber)-\(pv)-\(s)-\(t)-\(level)"
        XCTAssertEqual(location.id, "0----0")
    }

    func testId_UniqueForDifferentSubtitles() {
        let loc1 = TPPPDFLocation(title: "A", subtitle: "Sub1", pageLabel: nil, pageNumber: 1)
        let loc2 = TPPPDFLocation(title: "A", subtitle: "Sub2", pageLabel: nil, pageNumber: 1)

        XCTAssertNotEqual(loc1.id, loc2.id)
    }

    func testId_UniqueForDifferentPageLabels() {
        let loc1 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: "i", pageNumber: 1)
        let loc2 = TPPPDFLocation(title: "A", subtitle: nil, pageLabel: "ii", pageNumber: 1)

        XCTAssertNotEqual(loc1.id, loc2.id)
    }
}
