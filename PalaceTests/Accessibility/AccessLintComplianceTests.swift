//
//  AccessLintComplianceTests.swift
//  PalaceTests
//
//  Tests verifying AccessLint rule compliance for the Palace iOS app.
//  These tests guard against regressions in accessibility patterns
//  identified by the AccessLint WCAG AA audit.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - AccessLint Compliance Tests

final class AccessLintComplianceTests: XCTestCase {

    // MARK: - A11Y.SWIFTUI.TOUCH_TARGET — Minimum 44pt

    /// Verifies the expand/collapse button label provides both states.
    /// This was flagged because the chevron button had a 24pt frame;
    /// the fix enlarged it to 44pt and this test guards the label.
    func testExpandCollapseButton_hasDistinctLabelsForBothStates() {
        let expanded = Strings.Generic.collapseSection
        let collapsed = Strings.Generic.expandSection

        XCTAssertFalse(expanded.isEmpty, "Collapse label must not be empty")
        XCTAssertFalse(collapsed.isEmpty, "Expand label must not be empty")
        XCTAssertNotEqual(expanded, collapsed, "Labels must differ for expanded/collapsed states")
    }

    // MARK: - A11Y.SWIFTUI.LABEL_IN_NAME — Fallback labels

    /// TPPPDFToolbarButton was flagged for empty accessibility label
    /// when `accessibilityLabelText` was nil. Verify the fallback.
    func testPDFToolbarButton_fallbackLabel_isNotEmpty() {
        // The fix sets the fallback to `text ?? Strings.Generic.ok`
        let fallback = Strings.Generic.ok
        XCTAssertFalse(fallback.isEmpty, "Fallback label must not be empty")
    }

    // MARK: - A11Y.SWIFTUI.MEANINGFUL_NAME — Localized strings

    /// Ensures search announcement strings produce meaningful output.
    func testSearchAnnouncementStrings_areMeaningful() {
        let resultsMsg = Strings.SearchAnnouncements.searchResultsFound("cats", count: 3)
        XCTAssertTrue(resultsMsg.contains("3"), "Should contain count")
        XCTAssertTrue(resultsMsg.contains("cats"), "Should contain query")
        XCTAssertFalse(resultsMsg.isEmpty)

        let noResultsMsg = Strings.SearchAnnouncements.noSearchResults("zzzz")
        XCTAssertTrue(noResultsMsg.lowercased().contains("no results"))
        XCTAssertTrue(noResultsMsg.contains("zzzz"))

        let failedMsg = Strings.SearchAnnouncements.searchFailed()
        XCTAssertFalse(failedMsg.isEmpty)
        XCTAssertTrue(failedMsg.lowercased().contains("search"))
    }

    /// Ensures download announcement strings are descriptive.
    func testDownloadAnnouncementStrings_areMeaningful() {
        let started = Strings.DownloadAnnouncements.downloadStarted("Hamlet")
        XCTAssertTrue(started.contains("Hamlet"))
        XCTAssertTrue(started.lowercased().contains("download"))

        let completed = Strings.DownloadAnnouncements.downloadCompleted("Hamlet")
        XCTAssertTrue(completed.contains("Hamlet"))
        XCTAssertTrue(completed.lowercased().contains("completed") || completed.lowercased().contains("complete"))

        let failed = Strings.DownloadAnnouncements.downloadFailed("Hamlet")
        XCTAssertTrue(failed.contains("Hamlet"))
        XCTAssertTrue(failed.lowercased().contains("failed"))
    }

    /// Ensures borrow announcement strings are descriptive.
    func testBorrowAnnouncementStrings_areMeaningful() {
        let started = Strings.DownloadAnnouncements.borrowStarted("Dune")
        XCTAssertTrue(started.contains("Dune"))

        let succeeded = Strings.DownloadAnnouncements.borrowSucceeded("Dune")
        XCTAssertTrue(succeeded.contains("Dune"))

        let failed = Strings.DownloadAnnouncements.borrowFailed("Dune")
        XCTAssertTrue(failed.contains("Dune"))
        XCTAssertTrue(failed.lowercased().contains("failed"))
    }

    /// Ensures return announcement strings are descriptive.
    func testReturnAnnouncementStrings_areMeaningful() {
        let started = Strings.DownloadAnnouncements.returnStarted("1984")
        XCTAssertTrue(started.contains("1984"))

        let succeeded = Strings.DownloadAnnouncements.returnSucceeded("1984")
        XCTAssertTrue(succeeded.contains("1984"))

        let failed = Strings.DownloadAnnouncements.returnFailed("1984")
        XCTAssertTrue(failed.contains("1984"))
    }

    /// Ensures retry announcement strings are descriptive.
    func testRetryAnnouncementStrings_areMeaningful() {
        let retryBorrow = Strings.DownloadAnnouncements.retryingBorrow("Title A")
        XCTAssertTrue(retryBorrow.contains("Title A"))
        XCTAssertTrue(retryBorrow.lowercased().contains("retry") || retryBorrow.lowercased().contains("retrying"))

        let retryReturn = Strings.DownloadAnnouncements.retryingReturn("Title B")
        XCTAssertTrue(retryReturn.contains("Title B"))

        let retryDownload = Strings.DownloadAnnouncements.retryingDownload("Title C")
        XCTAssertTrue(retryDownload.contains("Title C"))
    }

    // MARK: - A11Y.SWIFTUI.ACCESSIBILITY_HINT — Informational

    /// Verifies sort/filter accessibility strings are descriptive.
    func testSortFilterLabels_areDescriptive() {
        let sortLabel = String(format: Strings.Generic.sortByFormat, "Title")
        XCTAssertTrue(sortLabel.contains("Title"))

        let filterWithCount = String(format: Strings.Generic.filterWithCount, 2)
        XCTAssertTrue(filterWithCount.contains("2"))

        let filterLabel = Strings.Generic.filter
        XCTAssertFalse(filterLabel.isEmpty)
    }

    // MARK: - A11Y.SWIFTUI.IMAGE_DECORATIVE — Regression Guard

    /// Audiobook badge label exists and is descriptive.
    func testAudiobookLabel_isDescriptive() {
        let label = Strings.Generic.audiobook
        XCTAssertFalse(label.isEmpty, "Audiobook label should not be empty")
        let lowercased = label.lowercased()
        XCTAssertTrue(lowercased.contains("audiobook"), "Should mention audiobook")
    }

    // MARK: - Status Announcement Strings Completeness

    /// StatusAnnouncements.errorOccurred passes through the message unchanged.
    func testStatusAnnouncement_errorOccurred_passesThrough() {
        let input = "Network connection lost."
        let output = Strings.StatusAnnouncements.errorOccurred(input)
        XCTAssertEqual(output, input, "errorOccurred should pass through the message as-is")
    }

    /// StatusAnnouncements.actionFailed combines title and message clearly.
    func testStatusAnnouncement_actionFailed_combinesTitleAndMessage() {
        let output = Strings.StatusAnnouncements.actionFailed(title: "Download Failed", message: "Please try again.")
        XCTAssertTrue(output.contains("Download Failed"))
        XCTAssertTrue(output.contains("Please try again."))
        // Verify there's a separator between title and message
        XCTAssertTrue(output.contains(". "), "Title and message should be separated by a period and space")
    }
}
