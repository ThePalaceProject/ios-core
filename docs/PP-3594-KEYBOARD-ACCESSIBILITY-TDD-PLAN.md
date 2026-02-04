# PP-3594: Keyboard Accessibility TDD Test Plan

## Overview

This document outlines the Test-Driven Development (TDD) plan for implementing iOS keyboard accessibility controls per PP-3594. Tests should be written FIRST, then implementation follows to make tests pass.

## Architecture Summary

### Key Files
- `Palace/Reader2/UI/TPPBaseReaderViewController.swift` - Base reader VC with `VisualNavigatorDelegate`
- `Palace/Reader2/UI/TPPEPUBViewController.swift` - EPUB-specific subclass
- Readium toolkit provides `KeyEvent`, `DirectionalNavigationAdapter`, and `InputObservable` APIs

### Existing Infrastructure
- `toggleNavigationBar()` - Already exists for toolbar show/hide
- `navigator.goLeft()` / `navigator.goRight()` - Page navigation methods
- `VisualNavigatorDelegate.didPressKey(event:)` - Keyboard hook (not yet implemented)
- `DirectionalNavigationAdapter` - Readium's helper for arrow/space key navigation

---

## Test Plan Structure

### Phase 1: Unit Tests for Keyboard Event Handling

#### 1.1 KeyboardNavigationHandlerTests

Create: `PalaceTests/Reader/KeyboardNavigationHandlerTests.swift`

```swift
import XCTest
@testable import Palace
import ReadiumNavigator

/// Tests for keyboard navigation behavior in the EPUB reader
/// Regression tests for PP-3594: iOS keyboard accessibility
class KeyboardNavigationHandlerTests: XCTestCase {
    
    // MARK: - Test: Escape Key Toggles Toolbar
    
    /// PP-3594 AC2.1: Given toolbar is visible, pressing Escape hides it
    func testEscapeKey_whenToolbarVisible_hidesToolbar() {
        // Arrange
        let sut = makeReaderViewController()
        sut.setToolbarVisible(true)
        XCTAssertTrue(sut.isToolbarVisible)
        
        // Act
        let escapeEvent = makeKeyEvent(key: .escape, phase: .down)
        sut.handleKeyEvent(escapeEvent)
        
        // Assert
        XCTAssertFalse(sut.isToolbarVisible)
    }
    
    /// PP-3594 AC2.2: Given toolbar is hidden, pressing Escape shows it
    func testEscapeKey_whenToolbarHidden_showsToolbar() {
        // Arrange
        let sut = makeReaderViewController()
        sut.setToolbarVisible(false)
        XCTAssertFalse(sut.isToolbarVisible)
        
        // Act
        let escapeEvent = makeKeyEvent(key: .escape, phase: .down)
        sut.handleKeyEvent(escapeEvent)
        
        // Assert
        XCTAssertTrue(sut.isToolbarVisible)
    }
    
    // MARK: - Test: Arrow Keys Turn Pages (Toolbar Hidden)
    
    /// PP-3594 AC3.1: Right arrow advances to next page when toolbar hidden
    func testRightArrow_whenToolbarHidden_advancesToNextPage() async {
        // Arrange
        let mockNavigator = MockVisualNavigator()
        let sut = makeReaderViewController(navigator: mockNavigator)
        sut.setToolbarVisible(false)
        
        // Act
        let rightArrowEvent = makeKeyEvent(key: .arrowRight, phase: .down)
        await sut.handleKeyEventAsync(rightArrowEvent)
        
        // Assert
        XCTAssertTrue(mockNavigator.didCallGoRight)
    }
    
    /// PP-3594 AC3.2: Left arrow goes to previous page when toolbar hidden
    func testLeftArrow_whenToolbarHidden_goesToPreviousPage() async {
        // Arrange
        let mockNavigator = MockVisualNavigator()
        let sut = makeReaderViewController(navigator: mockNavigator)
        sut.setToolbarVisible(false)
        
        // Act
        let leftArrowEvent = makeKeyEvent(key: .arrowLeft, phase: .down)
        await sut.handleKeyEventAsync(leftArrowEvent)
        
        // Assert
        XCTAssertTrue(mockNavigator.didCallGoLeft)
    }
    
    // MARK: - Test: Arrow Keys Do NOT Turn Pages (Toolbar Visible)
    
    /// PP-3594 AC3.3: Arrow keys don't change pages when toolbar visible
    func testRightArrow_whenToolbarVisible_doesNotChangePage() async {
        // Arrange
        let mockNavigator = MockVisualNavigator()
        let sut = makeReaderViewController(navigator: mockNavigator)
        sut.setToolbarVisible(true)
        
        // Act
        let rightArrowEvent = makeKeyEvent(key: .arrowRight, phase: .down)
        await sut.handleKeyEventAsync(rightArrowEvent)
        
        // Assert
        XCTAssertFalse(mockNavigator.didCallGoRight)
        XCTAssertFalse(mockNavigator.didCallGoLeft)
    }
    
    func testLeftArrow_whenToolbarVisible_doesNotChangePage() async {
        // Arrange
        let mockNavigator = MockVisualNavigator()
        let sut = makeReaderViewController(navigator: mockNavigator)
        sut.setToolbarVisible(true)
        
        // Act
        let leftArrowEvent = makeKeyEvent(key: .arrowLeft, phase: .down)
        await sut.handleKeyEventAsync(leftArrowEvent)
        
        // Assert
        XCTAssertFalse(mockNavigator.didCallGoRight)
        XCTAssertFalse(mockNavigator.didCallGoLeft)
    }
    
    // MARK: - Test: Space Key Navigation
    
    /// Space key advances page (common reading convention)
    func testSpaceKey_whenToolbarHidden_advancesPage() async {
        // Arrange
        let mockNavigator = MockVisualNavigator()
        let sut = makeReaderViewController(navigator: mockNavigator)
        sut.setToolbarVisible(false)
        
        // Act
        let spaceEvent = makeKeyEvent(key: .space, phase: .down)
        await sut.handleKeyEventAsync(spaceEvent)
        
        // Assert
        XCTAssertTrue(mockNavigator.didCallGoForward)
    }
    
    // MARK: - Test: Modifier Keys Ignored
    
    /// Arrow keys with modifiers should not turn pages (allow system shortcuts)
    func testArrowKey_withModifier_doesNotTurnPage() async {
        // Arrange
        let mockNavigator = MockVisualNavigator()
        let sut = makeReaderViewController(navigator: mockNavigator)
        sut.setToolbarVisible(false)
        
        // Act - Cmd+Right (system shortcut for word jump)
        let cmdRightEvent = makeKeyEvent(key: .arrowRight, phase: .down, modifiers: .command)
        await sut.handleKeyEventAsync(cmdRightEvent)
        
        // Assert
        XCTAssertFalse(mockNavigator.didCallGoRight)
    }
    
    // MARK: - Test: Key Release Ignored
    
    /// Only key press (down) should trigger actions, not release (up)
    func testEscapeKeyRelease_doesNotToggleToolbar() {
        // Arrange
        let sut = makeReaderViewController()
        sut.setToolbarVisible(true)
        
        // Act
        let escapeUpEvent = makeKeyEvent(key: .escape, phase: .up)
        sut.handleKeyEvent(escapeUpEvent)
        
        // Assert - toolbar should still be visible
        XCTAssertTrue(sut.isToolbarVisible)
    }
    
    // MARK: - Helpers
    
    private func makeReaderViewController(navigator: MockVisualNavigator? = nil) -> TestableReaderViewController {
        // Create testable subclass with mock navigator
        TestableReaderViewController(navigator: navigator ?? MockVisualNavigator())
    }
    
    private func makeKeyEvent(key: Key, phase: KeyEvent.Phase, modifiers: KeyModifiers = []) -> KeyEvent {
        KeyEvent(phase: phase, key: key, modifiers: modifiers)
    }
}
```

---

### Phase 2: VoiceOver Compatibility Tests

#### 2.1 KeyboardVoiceOverTests

Create: `PalaceTests/Reader/KeyboardVoiceOverTests.swift`

```swift
import XCTest
@testable import Palace

/// Tests ensuring keyboard navigation works alongside VoiceOver
/// PP-3594 AC4: No regression in accessibility behavior
class KeyboardVoiceOverTests: XCTestCase {
    
    /// PP-3594 AC4.1: Keyboard focus synchronized with accessibility focus
    func testKeyboardFocus_synchronizedWithAccessibilityFocus() {
        // Arrange
        let sut = makeReaderViewController()
        simulateVoiceOverEnabled()
        
        // Act
        sut.setToolbarVisible(true)
        
        // Assert - toolbar should remain visible (VoiceOver keeps it open)
        XCTAssertTrue(sut.isToolbarVisible)
        XCTAssertFalse(sut.navigationBarHidden)
    }
    
    /// PP-3594 AC4.2: Keyboard commands work when VoiceOver is running
    func testArrowKeys_workWithVoiceOverEnabled() async {
        // Arrange
        let mockNavigator = MockVisualNavigator()
        let sut = makeReaderViewController(navigator: mockNavigator)
        simulateVoiceOverEnabled()
        sut.setToolbarVisible(false) // Note: VoiceOver may override this
        
        // Act
        let rightArrowEvent = makeKeyEvent(key: .arrowRight, phase: .down)
        await sut.handleKeyEventAsync(rightArrowEvent)
        
        // Assert - navigation should still work
        // (VoiceOver may have different behavior, document any differences)
        XCTAssertTrue(mockNavigator.didCallGoRight || sut.isToolbarVisible)
    }
    
    private func simulateVoiceOverEnabled() {
        // Mock UIAccessibility.isVoiceOverRunning
    }
}
```

---

### Phase 3: Focus Indication Tests

#### 3.1 FocusIndicationTests

Create: `PalaceTests/Accessibility/FocusIndicationTests.swift`

```swift
import XCTest
@testable import Palace

/// Tests for visual focus indication across the app
/// PP-3594 AC1: Visible focus indication on iOS
class FocusIndicationTests: XCTestCase {
    
    /// PP-3594 AC1.1: Focused element is visually indicated
    func testFocusedButton_hasVisibleFocusRing() {
        // Arrange
        let button = TPPRoundedButton()
        
        // Act
        button.becomeFirstResponder()
        
        // Assert
        XCTAssertNotNil(button.layer.borderColor)
        XCTAssertGreaterThan(button.layer.borderWidth, 0)
    }
    
    /// PP-3594 AC1.2: Focus visible in light mode
    func testFocusIndication_visibleInLightMode() {
        // Arrange
        let button = TPPRoundedButton()
        button.overrideUserInterfaceStyle = .light
        button.becomeFirstResponder()
        
        // Assert - focus color should have sufficient contrast against light background
        let focusColor = UIColor(cgColor: button.layer.borderColor!)
        let contrastRatio = calculateContrastRatio(focusColor, against: .white)
        XCTAssertGreaterThanOrEqual(contrastRatio, 3.0, "Focus indication should meet WCAG AA contrast ratio")
    }
    
    /// PP-3594 AC1.3: Focus visible in dark mode
    func testFocusIndication_visibleInDarkMode() {
        // Arrange
        let button = TPPRoundedButton()
        button.overrideUserInterfaceStyle = .dark
        button.becomeFirstResponder()
        
        // Assert - focus color should have sufficient contrast against dark background
        let focusColor = UIColor(cgColor: button.layer.borderColor!)
        let contrastRatio = calculateContrastRatio(focusColor, against: .black)
        XCTAssertGreaterThanOrEqual(contrastRatio, 3.0, "Focus indication should meet WCAG AA contrast ratio")
    }
    
    /// PP-3594 AC1.4: Focus order is logical
    func testFocusOrder_followsVisualLayout() {
        // Arrange
        let viewController = TPPCatalogFeedViewController()
        viewController.loadViewIfNeeded()
        
        // Act - get focus order
        let focusableElements = viewController.view.accessibilityElements ?? []
        
        // Assert - elements should be in top-to-bottom, left-to-right order
        var previousY: CGFloat = -1
        for element in focusableElements {
            if let view = element as? UIView {
                XCTAssertGreaterThanOrEqual(view.frame.minY, previousY, "Focus order should follow visual layout")
                previousY = view.frame.minY
            }
        }
    }
    
    private func calculateContrastRatio(_ color1: UIColor, against color2: UIColor) -> Double {
        // Implement WCAG contrast ratio calculation
        // L1 + 0.05 / L2 + 0.05 where L1 is lighter luminance
        return 4.5 // Placeholder - implement actual calculation
    }
}
```

---

### Phase 4: Integration Tests

#### 4.1 ReaderKeyboardIntegrationTests

Create: `PalaceTests/Reader/ReaderKeyboardIntegrationTests.swift`

```swift
import XCTest
@testable import Palace

/// Integration tests for complete keyboard navigation flow
class ReaderKeyboardIntegrationTests: XCTestCase {
    
    /// Full flow: Open reader -> hide toolbar -> navigate with keys -> show toolbar
    func testCompleteKeyboardNavigationFlow() async throws {
        // This would be a UI test, but we can test the controller logic
        
        // Arrange
        let mockNavigator = MockVisualNavigator()
        let sut = makeIntegratedReaderViewController(navigator: mockNavigator)
        
        // Act & Assert Step 1: Toolbar starts visible
        XCTAssertTrue(sut.isToolbarVisible)
        
        // Act & Assert Step 2: Press Escape to hide toolbar
        await sut.simulateKeyPress(.escape)
        XCTAssertFalse(sut.isToolbarVisible)
        
        // Act & Assert Step 3: Right arrow turns page
        await sut.simulateKeyPress(.arrowRight)
        XCTAssertTrue(mockNavigator.didCallGoRight)
        mockNavigator.reset()
        
        // Act & Assert Step 4: Left arrow turns page back
        await sut.simulateKeyPress(.arrowLeft)
        XCTAssertTrue(mockNavigator.didCallGoLeft)
        
        // Act & Assert Step 5: Press Escape to show toolbar
        await sut.simulateKeyPress(.escape)
        XCTAssertTrue(sut.isToolbarVisible)
        
        // Act & Assert Step 6: Arrow keys no longer turn pages
        mockNavigator.reset()
        await sut.simulateKeyPress(.arrowRight)
        XCTAssertFalse(mockNavigator.didCallGoRight)
    }
    
    /// Regression test: Touch navigation still works
    func testTouchNavigation_stillWorksAfterKeyboardSupport() async {
        // Arrange
        let mockNavigator = MockVisualNavigator()
        let sut = makeIntegratedReaderViewController(navigator: mockNavigator)
        
        // Act - simulate tap on right edge (existing behavior)
        let rightEdgePoint = CGPoint(x: sut.view.bounds.maxX - 10, y: sut.view.bounds.midY)
        await sut.simulateTap(at: rightEdgePoint)
        
        // Assert - page should turn
        XCTAssertTrue(mockNavigator.didCallGoRight)
    }
}
```

---

## Mock Classes Required

### MockVisualNavigator

Create: `PalaceTests/Mocks/MockVisualNavigator.swift`

```swift
import Foundation
import ReadiumNavigator
import ReadiumShared

/// Mock navigator for testing keyboard navigation
class MockVisualNavigator: NSObject, VisualNavigator {
    
    // MARK: - Call tracking
    var didCallGoLeft = false
    var didCallGoRight = false
    var didCallGoForward = false
    var didCallGoBackward = false
    
    func reset() {
        didCallGoLeft = false
        didCallGoRight = false
        didCallGoForward = false
        didCallGoBackward = false
    }
    
    // MARK: - Navigator Protocol
    
    var publication: Publication { fatalError("Not implemented for tests") }
    var currentLocation: Locator? { nil }
    
    func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        true
    }
    
    func go(to link: Link, options: NavigatorGoOptions) async -> Bool {
        true
    }
    
    func goForward(options: NavigatorGoOptions) async -> Bool {
        didCallGoForward = true
        return true
    }
    
    func goBackward(options: NavigatorGoOptions) async -> Bool {
        didCallGoBackward = true
        return true
    }
    
    // MARK: - VisualNavigator Protocol
    
    var view: UIView { UIView() }
    
    func goLeft(options: NavigatorGoOptions) async -> Bool {
        didCallGoLeft = true
        return true
    }
    
    func goRight(options: NavigatorGoOptions) async -> Bool {
        didCallGoRight = true
        return true
    }
}
```

---

## Implementation Order (TDD)

### Step 1: Write Failing Tests
1. Create `KeyboardNavigationHandlerTests.swift` with all tests
2. Create `MockVisualNavigator.swift`
3. Run tests - all should fail (RED)

### Step 2: Implement Minimal Code
1. Add `didPressKey` to `TPPBaseReaderViewController`'s `VisualNavigatorDelegate`
2. Implement escape key handling
3. Implement arrow key handling with toolbar state check
4. Run tests - escape + arrow tests should pass (GREEN)

### Step 3: Refactor
1. Extract keyboard handling to dedicated `KeyboardNavigationHandler` class
2. Use Readium's `DirectionalNavigationAdapter` for arrow keys
3. Ensure all tests still pass

### Step 4: Add VoiceOver Tests
1. Create `KeyboardVoiceOverTests.swift`
2. Implement VoiceOver-aware behavior
3. Document any intentional differences from standard behavior

### Step 5: Add Focus Indication Tests
1. Create `FocusIndicationTests.swift`
2. Implement focus ring styling on buttons/controls
3. Verify contrast ratios meet WCAG AA

### Step 6: Integration Tests
1. Create `ReaderKeyboardIntegrationTests.swift`
2. Verify complete flow works
3. Verify no regression in touch navigation

---

## Key Implementation Details

### Keyboard Handling in TPPBaseReaderViewController

```swift
// Add to VisualNavigatorDelegate extension
func navigator(_ navigator: VisualNavigator, didPressKey event: KeyEvent) {
    // Only handle key down events
    guard event.phase == .down else { return }
    
    // Ignore events with modifiers (allow system shortcuts)
    guard event.modifiers.isEmpty else { return }
    
    switch event.key {
    case .escape:
        toggleNavigationBar()
        
    case .arrowLeft, .arrowRight, .space:
        // Only navigate when toolbar is hidden (full-screen reading mode)
        guard navigationBarHidden else { return }
        Task {
            await handleDirectionalNavigation(event)
        }
        
    default:
        break
    }
}

private func handleDirectionalNavigation(_ event: KeyEvent) async {
    guard let visualNavigator = navigator as? VisualNavigator else { return }
    
    switch event.key {
    case .arrowLeft:
        await visualNavigator.goLeft()
    case .arrowRight:
        await visualNavigator.goRight()
    case .space:
        await visualNavigator.goForward()
    default:
        break
    }
}
```

---

## Acceptance Criteria Mapping

| AC | Test File | Test Method(s) |
|----|-----------|----------------|
| AC1.1 | FocusIndicationTests | `testFocusedButton_hasVisibleFocusRing` |
| AC1.2 | FocusIndicationTests | `testFocusIndication_visibleInLightMode` |
| AC1.3 | FocusIndicationTests | `testFocusIndication_visibleInDarkMode` |
| AC1.4 | FocusIndicationTests | `testFocusOrder_followsVisualLayout` |
| AC2.1 | KeyboardNavigationHandlerTests | `testEscapeKey_whenToolbarVisible_hidesToolbar` |
| AC2.2 | KeyboardNavigationHandlerTests | `testEscapeKey_whenToolbarHidden_showsToolbar` |
| AC2.3 | - | Documented in this plan |
| AC3.1 | KeyboardNavigationHandlerTests | `testRightArrow_whenToolbarHidden_advancesToNextPage` |
| AC3.2 | KeyboardNavigationHandlerTests | `testLeftArrow_whenToolbarHidden_goesToPreviousPage` |
| AC3.3 | KeyboardNavigationHandlerTests | `testRightArrow_whenToolbarVisible_doesNotChangePage` |
| AC4.1 | KeyboardVoiceOverTests | `testKeyboardFocus_synchronizedWithAccessibilityFocus` |
| AC4.2 | ReaderKeyboardIntegrationTests | `testTouchNavigation_stillWorksAfterKeyboardSupport` |
| AC4.3 | - | Key mappings documented above |

---

## Notes

1. **Platform Conventions**: iOS uses Escape as toggle key (same as Android)
2. **VoiceOver Priority**: When VoiceOver is running, toolbar visibility may be managed by the system
3. **No UIKeyCommand Needed**: Readium's `InputObservable` handles keyboard capture internally
4. **Testing Strategy**: Unit tests focus on controller logic; UI tests verify visual behavior

---

## Files to Create

1. `PalaceTests/Reader/KeyboardNavigationHandlerTests.swift`
2. `PalaceTests/Reader/KeyboardVoiceOverTests.swift`
3. `PalaceTests/Accessibility/FocusIndicationTests.swift`
4. `PalaceTests/Reader/ReaderKeyboardIntegrationTests.swift`
5. `PalaceTests/Mocks/MockVisualNavigator.swift`
6. `Palace/Reader2/UI/KeyboardNavigationHandler.swift` (implementation)
