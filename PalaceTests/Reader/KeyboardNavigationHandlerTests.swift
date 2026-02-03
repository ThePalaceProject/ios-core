//
//  KeyboardNavigationHandlerTests.swift
//  PalaceTests
//
//  TDD tests for keyboard navigation behavior in the EPUB reader.
//  Regression tests for iOS keyboard accessibility.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import ReadiumNavigator

/// Tests for keyboard navigation behavior in the EPUB reader
@MainActor
final class KeyboardNavigationHandlerTests: XCTestCase {
  
  // MARK: - Properties
  
  private var mockNavigable: MockKeyboardNavigable!
  private var sut: KeyboardNavigationHandler!
  
  // MARK: - Setup / Teardown
  
  override func setUp() async throws {
    try await super.setUp()
    mockNavigable = MockKeyboardNavigable()
    sut = KeyboardNavigationHandler(navigable: mockNavigable)
  }
  
  override func tearDown() async throws {
    mockNavigable = nil
    sut = nil
    try await super.tearDown()
  }
  
  // MARK: - Test: Escape Key Toggles Toolbar
  
  /// AC2.1: Given toolbar is visible, pressing Escape hides it
  func testEscapeKey_whenToolbarVisible_togglesToolbar() async {
    // Arrange
    mockNavigable.toolbarHidden = false
    XCTAssertFalse(mockNavigable.isToolbarHidden, "Precondition: toolbar should be visible")
    
    // Act
    let escapeEvent = makeKeyEvent(key: .escape, phase: .down)
    let consumed = await sut.handleKeyEvent(escapeEvent)
    
    // Assert
    XCTAssertTrue(consumed, "Escape key should be consumed")
    XCTAssertTrue(mockNavigable.didCallToggleToolbar, "toggleToolbar should be called")
  }
  
  /// AC2.2: Given toolbar is hidden, pressing Escape shows it
  func testEscapeKey_whenToolbarHidden_togglesToolbar() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    XCTAssertTrue(mockNavigable.isToolbarHidden, "Precondition: toolbar should be hidden")
    
    // Act
    let escapeEvent = makeKeyEvent(key: .escape, phase: .down)
    let consumed = await sut.handleKeyEvent(escapeEvent)
    
    // Assert
    XCTAssertTrue(consumed, "Escape key should be consumed")
    XCTAssertTrue(mockNavigable.didCallToggleToolbar, "toggleToolbar should be called")
  }
  
  // MARK: - Test: Arrow Keys Turn Pages (Toolbar Hidden)
  
  /// AC3.1: Right arrow advances to next page when toolbar hidden
  func testRightArrow_whenToolbarHidden_advancesToNextPage() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act
    let rightArrowEvent = makeKeyEvent(key: .arrowRight, phase: .down)
    let consumed = await sut.handleKeyEvent(rightArrowEvent)
    
    // Assert
    XCTAssertTrue(consumed, "Right arrow should be consumed when toolbar hidden")
    XCTAssertTrue(mockNavigable.didCallNavigateRight, "navigateRight should be called")
    XCTAssertFalse(mockNavigable.didCallNavigateLeft, "navigateLeft should NOT be called")
  }
  
  /// AC3.2: Left arrow goes to previous page when toolbar hidden
  func testLeftArrow_whenToolbarHidden_goesToPreviousPage() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act
    let leftArrowEvent = makeKeyEvent(key: .arrowLeft, phase: .down)
    let consumed = await sut.handleKeyEvent(leftArrowEvent)
    
    // Assert
    XCTAssertTrue(consumed, "Left arrow should be consumed when toolbar hidden")
    XCTAssertTrue(mockNavigable.didCallNavigateLeft, "navigateLeft should be called")
    XCTAssertFalse(mockNavigable.didCallNavigateRight, "navigateRight should NOT be called")
  }
  
  // MARK: - Test: Arrow Keys Do NOT Turn Pages (Toolbar Visible)
  
  /// AC3.3: Arrow keys don't change pages when toolbar visible
  func testRightArrow_whenToolbarVisible_doesNotChangePage() async {
    // Arrange
    mockNavigable.toolbarHidden = false
    
    // Act
    let rightArrowEvent = makeKeyEvent(key: .arrowRight, phase: .down)
    let consumed = await sut.handleKeyEvent(rightArrowEvent)
    
    // Assert
    XCTAssertFalse(consumed, "Right arrow should NOT be consumed when toolbar visible")
    XCTAssertFalse(mockNavigable.didCallNavigateRight, "navigateRight should NOT be called")
    XCTAssertFalse(mockNavigable.didCallNavigateLeft, "navigateLeft should NOT be called")
  }
  
  func testLeftArrow_whenToolbarVisible_doesNotChangePage() async {
    // Arrange
    mockNavigable.toolbarHidden = false
    
    // Act
    let leftArrowEvent = makeKeyEvent(key: .arrowLeft, phase: .down)
    let consumed = await sut.handleKeyEvent(leftArrowEvent)
    
    // Assert
    XCTAssertFalse(consumed, "Left arrow should NOT be consumed when toolbar visible")
    XCTAssertFalse(mockNavigable.didCallNavigateRight, "navigateRight should NOT be called")
    XCTAssertFalse(mockNavigable.didCallNavigateLeft, "navigateLeft should NOT be called")
  }
  
  // MARK: - Test: Space Key Navigation
  
  /// Space key advances page (common reading convention)
  func testSpaceKey_whenToolbarHidden_advancesPage() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act
    let spaceEvent = makeKeyEvent(key: .space, phase: .down)
    let consumed = await sut.handleKeyEvent(spaceEvent)
    
    // Assert
    XCTAssertTrue(consumed, "Space key should be consumed when toolbar hidden")
    XCTAssertTrue(mockNavigable.didCallNavigateForward, "navigateForward should be called")
  }
  
  func testSpaceKey_whenToolbarVisible_doesNotAdvancePage() async {
    // Arrange
    mockNavigable.toolbarHidden = false
    
    // Act
    let spaceEvent = makeKeyEvent(key: .space, phase: .down)
    let consumed = await sut.handleKeyEvent(spaceEvent)
    
    // Assert
    XCTAssertFalse(consumed, "Space key should NOT be consumed when toolbar visible")
    XCTAssertFalse(mockNavigable.didCallNavigateForward, "navigateForward should NOT be called")
  }
  
  // MARK: - Test: Page Up/Down Keys
  
  func testPageDown_whenToolbarHidden_advancesPage() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act
    let pageDownEvent = makeKeyEvent(key: .pageDown, phase: .down)
    let consumed = await sut.handleKeyEvent(pageDownEvent)
    
    // Assert
    XCTAssertTrue(consumed, "PageDown should be consumed when toolbar hidden")
    XCTAssertTrue(mockNavigable.didCallNavigateForward, "navigateForward should be called")
  }
  
  func testPageUp_whenToolbarHidden_goesBackward() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act
    let pageUpEvent = makeKeyEvent(key: .pageUp, phase: .down)
    let consumed = await sut.handleKeyEvent(pageUpEvent)
    
    // Assert
    XCTAssertTrue(consumed, "PageUp should be consumed when toolbar hidden")
    XCTAssertTrue(mockNavigable.didCallNavigateLeft, "navigateLeft should be called (backward)")
  }
  
  // MARK: - Test: Modifier Keys Ignored
  
  /// Arrow keys with modifiers should not turn pages (allow system shortcuts)
  func testArrowKey_withCommandModifier_doesNotTurnPage() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act - Cmd+Right (system shortcut for word jump)
    let cmdRightEvent = makeKeyEvent(key: .arrowRight, phase: .down, modifiers: .command)
    let consumed = await sut.handleKeyEvent(cmdRightEvent)
    
    // Assert
    XCTAssertFalse(consumed, "Modified key should NOT be consumed")
    XCTAssertFalse(mockNavigable.didCallNavigateRight, "navigateRight should NOT be called with modifier")
  }
  
  func testArrowKey_withShiftModifier_doesNotTurnPage() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act - Shift+Left
    let shiftLeftEvent = makeKeyEvent(key: .arrowLeft, phase: .down, modifiers: .shift)
    let consumed = await sut.handleKeyEvent(shiftLeftEvent)
    
    // Assert
    XCTAssertFalse(consumed, "Modified key should NOT be consumed")
    XCTAssertFalse(mockNavigable.didCallNavigateLeft, "navigateLeft should NOT be called with modifier")
  }
  
  func testEscapeKey_withModifier_doesNotToggleToolbar() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act - Cmd+Escape
    let cmdEscapeEvent = makeKeyEvent(key: .escape, phase: .down, modifiers: .command)
    let consumed = await sut.handleKeyEvent(cmdEscapeEvent)
    
    // Assert
    XCTAssertFalse(consumed, "Modified escape should NOT be consumed")
    XCTAssertFalse(mockNavigable.didCallToggleToolbar, "toggleToolbar should NOT be called with modifier")
  }
  
  // MARK: - Test: Key Release Ignored
  
  /// Only key press (down) should trigger actions, not release (up)
  func testEscapeKeyRelease_doesNotToggleToolbar() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act
    let escapeUpEvent = makeKeyEvent(key: .escape, phase: .up)
    let consumed = await sut.handleKeyEvent(escapeUpEvent)
    
    // Assert
    XCTAssertFalse(consumed, "Key up should NOT be consumed")
    XCTAssertFalse(mockNavigable.didCallToggleToolbar, "toggleToolbar should NOT be called on key up")
  }
  
  func testArrowKeyRelease_doesNotTurnPage() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act
    let rightArrowUpEvent = makeKeyEvent(key: .arrowRight, phase: .up)
    let consumed = await sut.handleKeyEvent(rightArrowUpEvent)
    
    // Assert
    XCTAssertFalse(consumed, "Key up should NOT be consumed")
    XCTAssertFalse(mockNavigable.didCallNavigateRight, "navigateRight should NOT be called on key up")
  }
  
  // MARK: - Test: Unhandled Keys
  
  func testUnhandledKey_isNotConsumed() async {
    // Arrange
    mockNavigable.toolbarHidden = true
    
    // Act
    let letterEvent = makeKeyEvent(key: .a, phase: .down)
    let consumed = await sut.handleKeyEvent(letterEvent)
    
    // Assert
    XCTAssertFalse(consumed, "Unhandled key should NOT be consumed")
  }
  
  // MARK: - Helpers
  
  private func makeKeyEvent(key: Key, phase: KeyEvent.Phase, modifiers: KeyModifiers = []) -> KeyEvent {
    KeyEvent(phase: phase, key: key, modifiers: modifiers)
  }
}

// MARK: - Mock KeyboardNavigable

/// Mock implementation of KeyboardNavigable for testing
@MainActor
final class MockKeyboardNavigable: KeyboardNavigable {
  
  // MARK: - State
  
  var toolbarHidden: Bool = false
  
  // MARK: - Call Tracking
  
  private(set) var didCallToggleToolbar = false
  private(set) var didCallNavigateLeft = false
  private(set) var didCallNavigateRight = false
  private(set) var didCallNavigateForward = false
  
  // MARK: - Configuration
  
  var navigationSucceeds = true
  
  // MARK: - KeyboardNavigable Protocol
  
  var isToolbarHidden: Bool { toolbarHidden }
  
  func toggleToolbar() {
    didCallToggleToolbar = true
    toolbarHidden.toggle()
  }
  
  func navigateLeft() async -> Bool {
    didCallNavigateLeft = true
    return navigationSucceeds
  }
  
  func navigateRight() async -> Bool {
    didCallNavigateRight = true
    return navigationSucceeds
  }
  
  func navigateForward() async -> Bool {
    didCallNavigateForward = true
    return navigationSucceeds
  }
  
  // MARK: - Reset
  
  func reset() {
    didCallToggleToolbar = false
    didCallNavigateLeft = false
    didCallNavigateRight = false
    didCallNavigateForward = false
  }
}
