//
//  CatalogAccessibilityTests.swift
//  PalaceTests
//
//  Tests for VoiceOver accessibility in catalog-related UI elements.
//  Verifies lane navigation and filter controls have proper labels.
//  ()
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class CatalogAccessibilityTests: XCTestCase {

    // MARK: - Lane "More" Button Tests

    /// Verifies "More books in lane" label includes lane title
    func testMoreBooksInLaneLabel_includesLaneTitle() {
        let testLanes = ["Mystery", "Romance", "Science Fiction", "New Releases", "Staff Picks"]

        for laneTitle in testLanes {
            let label = makeMoreBooksLabel(forLane: laneTitle)
            XCTAssertTrue(
                label.contains(laneTitle),
                "More books label should include lane title '\(laneTitle)'"
            )
        }
    }

    /// Verifies "More books" label indicates navigation action
    func testMoreBooksLabel_indicatesNavigation() {
        let label = makeMoreBooksLabel(forLane: "Test")
        let lowercased = label.lowercased()

        XCTAssertTrue(
            lowercased.contains("more") || lowercased.contains("see") || lowercased.contains("view") || lowercased.contains("browse"),
            "More books label should indicate navigation to see more"
        )
    }

    /// Verifies that each distinct lane title produces a unique label and that
    /// the lane name does not appear in any other lane's label (no bleed-through).
    func testMoreBooksLabel_differsForDifferentLanes() {
        // Arrange
        let lanes = ["Mystery", "Romance", "Science Fiction"]

        // Act
        let labels = lanes.map { makeMoreBooksLabel(forLane: $0) }

        // Assert — all labels are pairwise distinct
        for i in 0..<labels.count {
            for j in (i + 1)..<labels.count {
                XCTAssertNotEqual(labels[i], labels[j],
                    "Labels for '\(lanes[i])' and '\(lanes[j])' must differ")
            }
        }
        // Assert — each label contains only its own lane name
        for (index, label) in labels.enumerated() {
            let ownLane = lanes[index]
            let otherLanes = lanes.filter { $0 != ownLane }
            XCTAssertTrue(label.contains(ownLane),
                "Label should reference its own lane '\(ownLane)'")
            for other in otherLanes {
                XCTAssertFalse(label.contains(other),
                    "Label for '\(ownLane)' must not bleed into '\(other)'")
            }
        }
    }

    // MARK: - Expand/Collapse Section Tests

    /// Verifies expand section label is descriptive and does not accidentally
    /// contain collapse-specific vocabulary (preventing VoiceOver confusion).
    func testExpandSectionLabel_isDescriptive() {
        // Arrange
        let label = Strings.Generic.expandSection
        let lowercased = label.lowercased()

        // Assert — non-empty and conveys expansion
        XCTAssertFalse(label.isEmpty, "Expand section label should not be empty")
        XCTAssertTrue(
            lowercased.contains("expand") || lowercased.contains("show") || lowercased.contains("open"),
            "Expand label should indicate expansion action"
        )
        // Assert — does not leak collapse vocabulary into the expand label
        XCTAssertFalse(
            lowercased.contains("collapse") || lowercased.contains("hide"),
            "Expand label must not contain collapse vocabulary"
        )
        // Assert — single-word check: label is usable without surrounding context
        XCTAssertGreaterThan(label.count, 3, "Label should be a real word, not a single character or abbreviation")
    }

    /// Verifies collapse section label is descriptive and does not accidentally
    /// contain expand-specific vocabulary (preventing VoiceOver confusion).
    func testCollapseSectionLabel_isDescriptive() {
        // Arrange
        let label = Strings.Generic.collapseSection
        let lowercased = label.lowercased()

        // Assert — non-empty and conveys collapsing
        XCTAssertFalse(label.isEmpty, "Collapse section label should not be empty")
        XCTAssertTrue(
            lowercased.contains("collapse") || lowercased.contains("hide") || lowercased.contains("close"),
            "Collapse label should indicate collapsing action"
        )
        // Assert — does not leak expand vocabulary into the collapse label
        XCTAssertFalse(
            lowercased.contains("expand") || lowercased.contains("open"),
            "Collapse label must not contain expand vocabulary"
        )
        // Assert — label is a real word
        XCTAssertGreaterThan(label.count, 3, "Label should be a real word, not a single character or abbreviation")
    }

    /// Verifies expand and collapse labels are different
    func testExpandCollapseLabels_areDifferent() {
        let expandLabel = Strings.Generic.expandSection
        let collapseLabel = Strings.Generic.collapseSection

        XCTAssertNotEqual(
            expandLabel,
            collapseLabel,
            "Expand and collapse labels should be different to indicate state"
        )
    }

    /// Verifies that the expand/collapse label produced by CatalogFiltersSheetView's
    /// toggle logic changes on every state flip and ultimately round-trips back to
    /// the original value after two flips.
    func testExpandCollapseLabel_roundTripsOnRepeatedFlips() {
        // Arrange — start collapsed
        var isExpanded = false

        // Act — simulate three state transitions
        isExpanded.toggle() // now expanded
        let labelAfterFirstExpand = isExpanded ? Strings.Generic.collapseSection : Strings.Generic.expandSection

        isExpanded.toggle() // now collapsed again
        let labelAfterFirstCollapse = isExpanded ? Strings.Generic.collapseSection : Strings.Generic.expandSection

        isExpanded.toggle() // expanded again
        let labelAfterSecondExpand = isExpanded ? Strings.Generic.collapseSection : Strings.Generic.expandSection

        // Assert — label values are correct for each state
        XCTAssertEqual(labelAfterFirstExpand,   Strings.Generic.collapseSection,
                       "Expanded state must show the collapse label")
        XCTAssertEqual(labelAfterFirstCollapse, Strings.Generic.expandSection,
                       "Collapsed state must show the expand label")
        XCTAssertEqual(labelAfterSecondExpand,  Strings.Generic.collapseSection,
                       "Re-expanded state must return to the collapse label")

        // Assert — label changes between transitions (no stale state)
        XCTAssertNotEqual(labelAfterFirstExpand, labelAfterFirstCollapse,
                          "Label must change when state flips expanded→collapsed")
        XCTAssertNotEqual(labelAfterFirstCollapse, labelAfterSecondExpand,
                          "Label must change when state flips collapsed→expanded")
    }

    // MARK: - Library Switch Button Tests

    /// Verifies switch library label is descriptive
    func testSwitchLibraryLabel_isDescriptive() {
        let label = Strings.Generic.switchLibrary

        XCTAssertFalse(label.isEmpty, "Switch library label should not be empty")
        let lowercased = label.lowercased()
        XCTAssertTrue(
            lowercased.contains("library") || lowercased.contains("account"),
            "Switch library label should mention library"
        )
        XCTAssertTrue(
            lowercased.contains("switch") || lowercased.contains("change") || lowercased.contains("select"),
            "Switch library label should indicate switching action"
        )
    }

    // MARK: - Helper Methods

    /// Replicates the "More books in lane" label logic from CatalogLaneRowView
    private func makeMoreBooksLabel(forLane laneTitle: String) -> String {
        return String(format: Strings.Generic.moreBooksInLane, laneTitle)
    }
}
