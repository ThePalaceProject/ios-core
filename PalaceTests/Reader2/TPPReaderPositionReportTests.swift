//
//  TPPReaderPositionReportTests.swift
//  PalaceTests
//
//  Tests the REAL TPPReaderPositionReport composer — the pure string-assembly
//  layer behind the DAISY nav-310 "Where am I?" announcement (PP-4527).
//

import XCTest
@testable import Palace

@MainActor
final class TPPReaderPositionReportTests: XCTestCase {

    // MARK: - All components present

    func testAnnouncement_allComponents_joinsSectionPagePercentInOrder() {
        let report = TPPReaderPositionReport.announcement(
            section: "Chapter 3",
            pageLabel: "12",
            totalProgression: 0.45
        )
        XCTAssertEqual(report, "Chapter 3, Page 12, 45% read")
    }

    // MARK: - No page-list (AC: section + % still reported, no error)

    func testAnnouncement_noPageLabel_omitsPageButKeepsSectionAndPercent() {
        let report = TPPReaderPositionReport.announcement(
            section: "Introduction",
            pageLabel: nil,
            totalProgression: 0.10
        )
        XCTAssertEqual(report, "Introduction, 10% read")
        XCTAssertFalse(report.contains("Page"), "no page-list must not yield a page component")
    }

    func testAnnouncement_emptyPageLabel_treatedAsAbsent() {
        let report = TPPReaderPositionReport.announcement(
            section: "Introduction",
            pageLabel: "   ",
            totalProgression: 0.10
        )
        XCTAssertEqual(report, "Introduction, 10% read")
    }

    // MARK: - No section

    func testAnnouncement_noSection_omitsSection() {
        let report = TPPReaderPositionReport.announcement(
            section: nil,
            pageLabel: "7",
            totalProgression: 0.33
        )
        XCTAssertEqual(report, "Page 7, 33% read")
    }

    func testAnnouncement_emptyOrWhitespaceSection_omitsSection() {
        let report = TPPReaderPositionReport.announcement(
            section: "   ",
            pageLabel: "7",
            totalProgression: 0.33
        )
        XCTAssertEqual(report, "Page 7, 33% read")
    }

    // MARK: - Percentage rounding / clamping

    func testAnnouncement_percentageRoundsToNearestWholePercent() {
        // 0.455 -> 45.5 -> rounds AWAY from .5 to 46 (kills the truncate mutant,
        // which would render 45).
        let up = TPPReaderPositionReport.announcement(section: nil, pageLabel: nil, totalProgression: 0.455)
        XCTAssertEqual(up, "46% read")

        let down = TPPReaderPositionReport.announcement(section: nil, pageLabel: nil, totalProgression: 0.454)
        XCTAssertEqual(down, "45% read")
    }

    func testAnnouncement_percentageClampsToZeroAndOneHundred() {
        let over = TPPReaderPositionReport.announcement(section: nil, pageLabel: nil, totalProgression: 1.5)
        XCTAssertEqual(over, "100% read")

        let under = TPPReaderPositionReport.announcement(section: nil, pageLabel: nil, totalProgression: -0.2)
        XCTAssertEqual(under, "0% read")
    }

    func testAnnouncement_noPercentage_omitsPercentComponent() {
        let report = TPPReaderPositionReport.announcement(
            section: "Chapter 1",
            pageLabel: "3",
            totalProgression: nil
        )
        XCTAssertEqual(report, "Chapter 1, Page 3")
        XCTAssertFalse(report.contains("%"), "nil progression must not yield a percent component")
    }

    // MARK: - Degenerate (nothing available)

    func testAnnouncement_nothingAvailable_returnsUnavailableFallback() {
        let report = TPPReaderPositionReport.announcement(
            section: nil,
            pageLabel: nil,
            totalProgression: nil
        )
        XCTAssertEqual(report, "Current position unavailable")
    }

    func testAnnouncement_onlySection_returnsSectionAlone() {
        let report = TPPReaderPositionReport.announcement(
            section: "Prologue",
            pageLabel: nil,
            totalProgression: nil
        )
        XCTAssertEqual(report, "Prologue")
    }
}
