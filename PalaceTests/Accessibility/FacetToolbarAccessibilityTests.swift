//
//  FacetToolbarAccessibilityTests.swift
//  PalaceTests
//
//  Tests for VoiceOver accessibility in FacetToolbarView.
//  Verifies sort and filter buttons have proper dynamic labels.
//  ()
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class FacetToolbarAccessibilityTests: XCTestCase {

    // MARK: - Sort Button Accessibility

    /// Verifies sort button accessibility label includes the current sort option
    func testSortButtonLabel_includesSortOption() {
        let sortOptions = ["Author", "Title", "Recent"]

        for option in sortOptions {
            let label = makeSortAccessibilityLabel(sortOption: option)
            XCTAssertTrue(
                label.contains(option),
                "Sort accessibility label should include '\(option)'"
            )
        }
    }

    /// Verifies the sort button label format is consistent across all sort options
    /// and that changing the active sort produces a new, distinct label.
    func testSortButtonLabel_hasConsistentFormat() {
        // Arrange
        let options = ["Author", "Title", "Recent"]

        // Act
        let labels = options.map { makeSortAccessibilityLabel(sortOption: $0) }

        // Assert — template suffix is identical (only the option word changes)
        let prefixes = zip(options, labels).map { option, label in
            label.replacingOccurrences(of: option, with: "")
        }
        XCTAssertEqual(prefixes[0], prefixes[1], "Author and Title sort labels must share the same format template")
        XCTAssertEqual(prefixes[1], prefixes[2], "Title and Recent sort labels must share the same format template")

        // Assert — all labels are pairwise distinct (VoiceOver reads each differently)
        for i in 0..<labels.count {
            for j in (i + 1)..<labels.count {
                XCTAssertNotEqual(labels[i], labels[j],
                    "Labels for '\(options[i])' and '\(options[j])' must be distinct")
            }
        }

        // Assert — simulated sort change: label updates when active option changes
        let initialLabel = makeSortAccessibilityLabel(sortOption: options[0])
        let updatedLabel = makeSortAccessibilityLabel(sortOption: options[1])
        XCTAssertNotEqual(initialLabel, updatedLabel,
            "Changing the active sort option must produce a new accessibility label")
    }

    // MARK: - Filter Button Accessibility

    /// Verifies filter button label when no filters are applied equals the plain
    /// filter string, and that adding then removing filters round-trips back to
    /// the zero-filter label.
    func testFilterButtonLabel_noFiltersApplied() {
        // Arrange / Act
        let zeroLabel    = makeFilterAccessibilityLabel(appliedCount: 0)
        let oneLabel     = makeFilterAccessibilityLabel(appliedCount: 1)
        let backToZero   = makeFilterAccessibilityLabel(appliedCount: 0)

        // Assert — zero state equals plain filter string
        XCTAssertEqual(zeroLabel, Strings.Generic.filter,
            "Zero-filter label should be the plain filter string")

        // Assert — label changes when filter applied
        XCTAssertNotEqual(zeroLabel, oneLabel,
            "Label must change when a filter is applied")

        // Assert — removing the filter restores the zero-filter label
        XCTAssertEqual(backToZero, zeroLabel,
            "Label must return to plain filter string after all filters removed")

        // Assert — plain filter label is non-empty
        XCTAssertFalse(zeroLabel.isEmpty, "Filter label must not be empty")
    }

    /// Verifies filter button label includes count when filters are applied,
    /// and that the count increments correctly with each additional filter.
    func testFilterButtonLabel_withFiltersApplied() {
        let testCounts = [1, 2, 5, 10]

        for count in testCounts {
            // Act
            let label = makeFilterAccessibilityLabel(appliedCount: count)

            // Assert — count is present in the label
            XCTAssertTrue(
                label.contains("\(count)"),
                "Filter label should include count '\(count)' when filters applied"
            )
            // Assert — the label is distinct from the zero-filter label
            XCTAssertNotEqual(label, Strings.Generic.filter,
                "A label with \(count) filter(s) must differ from the plain filter label")
        }

        // Assert — each count produces a unique label (no two counts collide)
        let labels = testCounts.map { makeFilterAccessibilityLabel(appliedCount: $0) }
        for i in 0..<labels.count {
            for j in (i + 1)..<labels.count {
                XCTAssertNotEqual(labels[i], labels[j],
                    "Labels for count \(testCounts[i]) and \(testCounts[j]) must be distinct")
            }
        }
    }

    /// Verifies filter label transitions through zero → n → zero and that
    /// the zero-state label matches the canonical filter string at each visit.
    func testFilterButtonLabel_differsBasedOnFilterState() {
        // Arrange
        let counts = [0, 1, 3, 0]

        // Act
        let labels = counts.map { makeFilterAccessibilityLabel(appliedCount: $0) }

        // Assert — non-zero count labels differ from zero-count label
        XCTAssertNotEqual(labels[0], labels[1], "Adding 1 filter must change the label")
        XCTAssertNotEqual(labels[1], labels[2], "Adding more filters must change the label")
        XCTAssertNotEqual(labels[2], labels[3], "Clearing filters must change the label")

        // Assert — both zero-count visits produce the canonical label
        XCTAssertEqual(labels[0], labels[3],
            "Zero-filter label must be the same before and after applying filters")
        XCTAssertEqual(labels[0], Strings.Generic.filter,
            "Zero-filter label must equal the canonical filter string")
    }

    // MARK: - Helper Methods

    /// Replicates the sort button accessibility label logic from FacetToolbarView
    private func makeSortAccessibilityLabel(sortOption: String) -> String {
        return String(format: Strings.Generic.sortByFormat, sortOption)
    }

    /// Replicates the filter button accessibility label logic from FacetToolbarView
    private func makeFilterAccessibilityLabel(appliedCount: Int) -> String {
        if appliedCount > 0 {
            return String(format: Strings.Generic.filterWithCount, appliedCount)
        } else {
            return Strings.Generic.filter
        }
    }
}
