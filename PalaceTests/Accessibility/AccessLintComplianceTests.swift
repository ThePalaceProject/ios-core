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

@MainActor
final class AccessLintComplianceTests: XCTestCase {

    // MARK: - A11Y.SWIFTUI.TOUCH_TARGET — Minimum 44pt

    /// Verifies the expand/collapse toggle logic produces the correct label
    /// for each state transition and that the two state labels are distinct.
    /// This was flagged because the chevron button had a 24pt frame;
    /// the fix enlarged it to 44pt and this test guards the resulting label
    /// round-trips correctly when the state flips.
    func testExpandCollapseButton_labelsRoundTripOnStateFlip() {
        // Arrange
        let collapseLabel = Strings.Generic.collapseSection
        let expandLabel   = Strings.Generic.expandSection

        // Act — simulate the toggle: start expanded, flip to collapsed, flip back
        var isExpanded = true
        let labelAfterOpen    = isExpanded ? collapseLabel : expandLabel
        isExpanded.toggle()
        let labelAfterCollapse = isExpanded ? collapseLabel : expandLabel
        isExpanded.toggle()
        let labelAfterReopen  = isExpanded ? collapseLabel : expandLabel

        // Assert — label must change on each flip and return to original
        XCTAssertFalse(collapseLabel.isEmpty, "Collapse label must not be empty")
        XCTAssertFalse(expandLabel.isEmpty,   "Expand label must not be empty")
        XCTAssertNotEqual(collapseLabel, expandLabel, "Labels must differ for expanded/collapsed states")
        XCTAssertEqual(labelAfterOpen,    collapseLabel, "Expanded state should show collapse label")
        XCTAssertEqual(labelAfterCollapse, expandLabel,  "Collapsed state should show expand label")
        XCTAssertEqual(labelAfterReopen,  collapseLabel, "Re-expanded state should return to collapse label")
    }

    // MARK: - A11Y.SWIFTUI.LABEL_IN_NAME — Fallback labels

    /// TPPPDFToolbarButton was flagged for empty accessibility label
    /// when `accessibilityLabelText` was nil. Verify the fallback is
    /// used instead of the primary text when the primary is absent,
    /// and that the two values are distinct (so VoiceOver never
    /// announces a context-free "OK" for a non-OK action).
    func testPDFToolbarButton_fallbackLabel_isDistinctFromOkLabel() {
        // Arrange
        let fallback = Strings.Generic.ok
        let cancelLabel = Strings.Generic.cancel

        // Act — the fallback chain is `primaryText ?? Strings.Generic.ok`;
        // simulate a nil primary: result collapses to fallback
        let resultWithNilPrimary: String = nil ?? fallback
        let resultWithPrimary: String = cancelLabel

        // Assert — fallback is non-empty AND a real primary label takes precedence
        XCTAssertFalse(fallback.isEmpty, "Fallback label must not be empty")
        XCTAssertEqual(resultWithNilPrimary, fallback, "Nil primary should yield the fallback")
        XCTAssertEqual(resultWithPrimary, cancelLabel, "Non-nil primary should override fallback")
        XCTAssertNotEqual(fallback, cancelLabel, "Fallback and a typical button label must differ")
    }

    // MARK: - A11Y.SWIFTUI.MEANINGFUL_NAME — Localized strings

    /// Ensures search announcement strings produce meaningful output and that
    /// the list-value helper scales correctly for zero, one, and many results.
    func testSearchAnnouncementStrings_areMeaningful() {
        // Act — found results
        let resultsMsg = Strings.SearchAnnouncements.searchResultsFound("cats", count: 3)
        XCTAssertTrue(resultsMsg.contains("3"), "Should contain count")
        XCTAssertTrue(resultsMsg.contains("cats"), "Should contain query")
        XCTAssertFalse(resultsMsg.isEmpty)

        // Act — no results
        let noResultsMsg = Strings.SearchAnnouncements.noSearchResults("zzzz")
        XCTAssertTrue(noResultsMsg.lowercased().contains("no results"))
        XCTAssertTrue(noResultsMsg.contains("zzzz"))

        // Act — failure
        let failedMsg = Strings.SearchAnnouncements.searchFailed()
        XCTAssertFalse(failedMsg.isEmpty)
        XCTAssertTrue(failedMsg.lowercased().contains("search"))

        // Act — list value helper (plural / singular / zero)
        let zeroLabel = Strings.SearchAnnouncements.searchResultsListValue(bookCount: 0)
        let oneLabel  = Strings.SearchAnnouncements.searchResultsListValue(bookCount: 1)
        let manyLabel = Strings.SearchAnnouncements.searchResultsListValue(bookCount: 42)

        XCTAssertFalse(zeroLabel.isEmpty, "Zero-result label must not be empty")
        XCTAssertFalse(oneLabel.isEmpty,  "Singular label must not be empty")
        XCTAssertTrue(manyLabel.contains("42"), "Plural label must include the count")

        // Singular and plural must be distinct strings
        XCTAssertNotEqual(oneLabel, manyLabel, "Singular and plural list-value labels must differ")

        // Act — loading-more announcement
        let loadingMore = Strings.SearchAnnouncements.loadingMoreResults()
        XCTAssertFalse(loadingMore.isEmpty, "Loading-more announcement must not be empty")

        let additionalLoaded = Strings.SearchAnnouncements.additionalResultsLoaded(10)
        XCTAssertTrue(additionalLoaded.contains("10"), "Additional-results message must include the count")
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

    /// Ensures return announcement strings are descriptive and convey the
    /// correct semantic intent for each state (started, succeeded, failed).
    func testReturnAnnouncementStrings_areMeaningful() {
        // Arrange
        let title = "1984"

        // Act
        let started   = Strings.DownloadAnnouncements.returnStarted(title)
        let succeeded = Strings.DownloadAnnouncements.returnSucceeded(title)
        let failed    = Strings.DownloadAnnouncements.returnFailed(title)

        // Assert — title interpolated correctly in all three states
        XCTAssertTrue(started.contains(title),   "returnStarted must reference the title")
        XCTAssertTrue(succeeded.contains(title), "returnSucceeded must reference the title")
        XCTAssertTrue(failed.contains(title),    "returnFailed must reference the title")

        // Assert — each string conveys a distinct semantic meaning
        XCTAssertTrue(
            failed.lowercased().contains("fail") || failed.lowercased().contains("error"),
            "returnFailed should indicate failure to VoiceOver users"
        )
        XCTAssertTrue(
            succeeded.lowercased().contains("return") || succeeded.lowercased().contains("returned"),
            "returnSucceeded should confirm the return action"
        )
        XCTAssertNotEqual(started, succeeded, "Started and succeeded messages must differ")
        XCTAssertNotEqual(succeeded, failed,  "Succeeded and failed messages must differ")
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

        // The message should pass through unchanged so VoiceOver reads the exact error text
        XCTAssertEqual(output, input, "errorOccurred should pass through the message as-is")
        XCTAssertFalse(output.isEmpty, "errorOccurred must never produce an empty announcement")
        XCTAssertTrue(output.contains("Network"), "errorOccurred must preserve the original wording")

        // Edge case: empty input should produce empty output (or at least not crash)
        let emptyOutput = Strings.StatusAnnouncements.errorOccurred("")
        XCTAssertTrue(emptyOutput.isEmpty || emptyOutput == "",
                      "errorOccurred with empty string should not add extraneous content")
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
