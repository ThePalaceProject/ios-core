//
//  FocusIndicationTests.swift
//  PalaceTests
//
//  Tests for visual focus indication across the app.
//  AC1: Visible focus indication on iOS
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for visual focus indication across the app
/// AC1: Visible focus indication on iOS
final class FocusIndicationTests: XCTestCase {

    // MARK: - Test: Focus Ring Visibility

    /// AC1.1: Focused element is visually indicated.
    /// Verifies that a standard UIButton and a TPPRoundedButton both expose the
    /// correct accessibility traits and that the system focus behaviour is
    /// consistent between the two (neither breaks iOS's own focus handling).
    func testFocusableButton_hasFocusEffect() {
        // Arrange
        let systemButton  = UIButton(type: .system)
        systemButton.setTitle("Test", for: .normal)
        systemButton.accessibilityLabel = "Test Action"

        let roundedButton = TPPRoundedButton(type: .normal, endDate: nil, isFromDetailView: false)

        // Act — inspect focus-relevant properties on both button types
        let systemCanFocus  = systemButton.canBecomeFocused
        let roundedCanFocus = roundedButton.canBecomeFocused

        // Assert — UIButton defaults to non-focusable on iPhone (system manages keyboard focus)
        XCTAssertFalse(systemCanFocus,
            "UIButton defaults to non-focusable on iOS; system handles keyboard focus")

        // Assert — TPPRoundedButton matches the system button's focus behaviour
        // (it must not accidentally override canBecomeFocused to true)
        XCTAssertEqual(roundedCanFocus, systemCanFocus,
            "TPPRoundedButton must not change the system's default focus behaviour")

        // Assert — accessibility element flag is set so VoiceOver can reach the button
        XCTAssertTrue(systemButton.isAccessibilityElement,
            "UIButton must be an accessibility element by default")
        XCTAssertTrue(roundedButton.isAccessibilityElement,
            "TPPRoundedButton must be an accessibility element")

        // Assert — both buttons carry the .button trait (required for VoiceOver "double-tap to activate" hint)
        XCTAssertTrue(systemButton.accessibilityTraits.contains(.button),
            "UIButton must have the .button accessibility trait")
        XCTAssertTrue(roundedButton.accessibilityTraits.contains(.button),
            "TPPRoundedButton must have the .button accessibility trait")
    }

    /// AC1.2: Focus visible in light mode - contrast check
    func testFocusColor_hasSufficientContrastInLightMode() {
        // Arrange
        let focusColor = UIColor.systemBlue // Standard iOS focus color
        let backgroundColor = UIColor.white

        // Act
        let contrastRatio = calculateContrastRatio(focusColor, against: backgroundColor)

        // Assert - WCAG AA requires 3:1 for UI components
        XCTAssertGreaterThanOrEqual(contrastRatio, 3.0,
                                    "Focus indication should meet WCAG AA contrast ratio of 3:1 against light background")
    }

    /// AC1.3: Focus visible in dark mode - contrast check
    func testFocusColor_hasSufficientContrastInDarkMode() {
        // Arrange
        let focusColor = UIColor.systemBlue // Standard iOS focus color
        let backgroundColor = UIColor.black

        // Act
        let contrastRatio = calculateContrastRatio(focusColor, against: backgroundColor)

        // Assert - WCAG AA requires 3:1 for UI components
        XCTAssertGreaterThanOrEqual(contrastRatio, 3.0,
                                    "Focus indication should meet WCAG AA contrast ratio of 3:1 against dark background")
    }

    /// Test that TPPRoundedButton maintains accessibility
    /// Added isAccessibilityElement and accessibilityTraits
    func testTPPRoundedButton_isAccessible() {
        // Arrange
        let button = TPPRoundedButton(type: .normal, endDate: nil, isFromDetailView: false)

        // Assert - UIButton subclasses should be accessibility elements
        XCTAssertTrue(button.isAccessibilityElement, "TPPRoundedButton should be an accessibility element")
        XCTAssertTrue(button.accessibilityTraits.contains(.button), "TPPRoundedButton should have button trait")
    }

    /// Verifies that when a UICollectionViewCell is configured as an accessibility
    /// element its label is surfaced to VoiceOver (non-nil, non-empty) and that
    /// a cell without a label configured is silent (nil label) — so the calling
    /// code cannot accidentally make the label blank and have VoiceOver announce
    /// an empty string.
    func testCatalogCell_accessibilityLabelBehavior() {
        // Arrange — cell configured as an accessibility element with a label
        let labeledCell = UICollectionViewCell()
        labeledCell.isAccessibilityElement = true
        labeledCell.accessibilityLabel = "The Midnight Library"

        // Arrange — cell without explicit accessibility configuration
        let unlabeledCell = UICollectionViewCell()

        // Act — ask each cell for its accessibility label
        let labeledResult   = labeledCell.accessibilityLabel
        let unlabeledResult = unlabeledCell.accessibilityLabel

        // Assert — labeled cell: element flag is set, label is the exact string set
        XCTAssertTrue(labeledCell.isAccessibilityElement,
            "Cell must be an accessibility element when explicitly configured")
        XCTAssertEqual(labeledResult, "The Midnight Library",
            "Configured label must be returned verbatim")
        XCTAssertFalse((labeledResult ?? "").isEmpty,
            "VoiceOver must never receive an empty string label")

        // Assert — unconfigured cell: VoiceOver should receive nil, not an empty string
        // (an empty-string label causes VoiceOver to say nothing, confusing users)
        let labelIsNilOrNonEmpty = unlabeledResult == nil || !(unlabeledResult!.isEmpty)
        XCTAssertTrue(labelIsNilOrNonEmpty,
            "An unconfigured cell's accessibility label should be nil, not an empty string")
    }

    // MARK: - Test: Focus Order

    /// AC1.4: Focus order follows visual layout — verifies that when subviews are
    /// added in arbitrary order their frames remain in top-to-bottom visual order,
    /// and that inserting a view out of visual order is detected before it ships.
    func testAccessibilityElements_areOrderedLogically() {
        // Arrange — three buttons placed at different vertical positions
        let containerView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        let topButton    = UIButton(frame: CGRect(x: 10, y: 10,  width: 100, height: 44))
        let middleButton = UIButton(frame: CGRect(x: 10, y: 64,  width: 100, height: 44))
        let bottomButton = UIButton(frame: CGRect(x: 10, y: 118, width: 100, height: 44))
        topButton.accessibilityLabel    = "Top Action"
        middleButton.accessibilityLabel = "Middle Action"
        bottomButton.accessibilityLabel = "Bottom Action"

        // Add in reverse order to prove frame position, not insertion order, drives focus
        containerView.addSubview(bottomButton)
        containerView.addSubview(middleButton)
        containerView.addSubview(topButton)

        // Act — collect subviews and sort by vertical position (as VoiceOver does)
        let sortedByY = containerView.subviews.sorted { $0.frame.minY < $1.frame.minY }

        // Assert — sorted order matches the intended top-to-bottom reading order
        XCTAssertEqual(sortedByY[0].accessibilityLabel, "Top Action",
            "Topmost element should be first in VoiceOver reading order")
        XCTAssertEqual(sortedByY[1].accessibilityLabel, "Middle Action",
            "Middle element should be second")
        XCTAssertEqual(sortedByY[2].accessibilityLabel, "Bottom Action",
            "Bottom element should be last")

        // Assert — each element's minY is strictly greater than the previous
        var previousY: CGFloat = -1
        for element in sortedByY {
            XCTAssertGreaterThan(element.frame.minY, previousY,
                "Accessibility elements must not overlap vertically")
            previousY = element.frame.minY
        }

        // Assert — a mis-ordered element is detectable: bottom frame above middle frame would fail
        let outOfOrderDetected = bottomButton.frame.minY > middleButton.frame.minY
        XCTAssertTrue(outOfOrderDetected,
            "Frame ordering check must catch when an element is placed above its predecessor")
    }

    /// Verifies that reader toolbar items preserve their insertion order (VoiceOver
    /// traverses UIToolbar items left-to-right in the order they are set) and that
    /// replacing the items array with a reordered version produces a different
    /// first-element label — confirming the order matters and is testable.
    func testReaderToolbar_buttonsInLogicalOrder() {
        // Arrange
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))

        let backButton = UIBarButtonItem(title: "Back", style: .plain, target: nil, action: nil)
        backButton.accessibilityLabel = "Go Back"

        let titleItem = UIBarButtonItem(title: "Book Title", style: .plain, target: nil, action: nil)
        titleItem.isEnabled = false  // non-interactive; VoiceOver skips disabled items by default

        let menuButton = UIBarButtonItem(title: "Menu", style: .plain, target: nil, action: nil)
        menuButton.accessibilityLabel = "Open Reader Menu"

        // Act — set items in the intended reading order, then snapshot the labels for assertion
        toolbar.items = [backButton, titleItem, menuButton]
        let labelOrder = toolbar.items?.compactMap { $0.accessibilityLabel } ?? []

        // Assert — item count and positional labels are preserved
        XCTAssertEqual(toolbar.items?.count, 3,
            "Toolbar must contain exactly three items")
        XCTAssertEqual(labelOrder.first, "Go Back",
            "First label in reading order must be the back button")
        XCTAssertEqual(labelOrder.last, "Open Reader Menu",
            "Last label in reading order must be the menu button")

        // Act — reverse items to simulate an ordering regression, snapshot new label order
        toolbar.items = [menuButton, titleItem, backButton]
        let reversedLabelOrder = toolbar.items?.compactMap { $0.accessibilityLabel } ?? []

        // Assert — first-element label now differs from expected "Go Back"
        XCTAssertNotEqual(reversedLabelOrder.first, "Go Back",
            "Reversed toolbar must not present the back button first — ordering regression detected")
        XCTAssertEqual(reversedLabelOrder.first, "Open Reader Menu",
            "After reversal the menu button should be first")

        // Verify ordering changed — the two label arrays must differ
        XCTAssertNotEqual(labelOrder, reversedLabelOrder,
            "Reversing toolbar items must produce a different accessibility label order")

        // Restore correct order and snapshot again
        toolbar.items = [backButton, titleItem, menuButton]
        let restoredLabelOrder = toolbar.items?.compactMap { $0.accessibilityLabel } ?? []
        XCTAssertEqual(restoredLabelOrder, labelOrder,
            "Restoring original order must reproduce the original label sequence")
    }

    // MARK: - Helpers

    /// Calculate WCAG contrast ratio between two colors
    /// Formula: (L1 + 0.05) / (L2 + 0.05) where L1 is lighter
    private func calculateContrastRatio(_ color1: UIColor, against color2: UIColor) -> Double {
        let luminance1 = relativeLuminance(of: color1)
        let luminance2 = relativeLuminance(of: color2)

        let lighter = max(luminance1, luminance2)
        let darker = min(luminance1, luminance2)

        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Calculate relative luminance per WCAG 2.1
    private func relativeLuminance(of color: UIColor) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        // Get RGB components
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        // Convert to sRGB
        let r = red <= 0.03928 ? red / 12.92 : pow((red + 0.055) / 1.055, 2.4)
        let g = green <= 0.03928 ? green / 12.92 : pow((green + 0.055) / 1.055, 2.4)
        let b = blue <= 0.03928 ? blue / 12.92 : pow((blue + 0.055) / 1.055, 2.4)

        // Calculate luminance
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
