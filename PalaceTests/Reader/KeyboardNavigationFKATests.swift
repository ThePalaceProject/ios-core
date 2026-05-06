//
//  KeyboardNavigationFKATests.swift
//  PalaceTests
//
//  Tests for Full Keyboard Access (FKA) behavior and handleCommand
//  in KeyboardNavigationHandler.
//
//  When FKA is enabled, arrow keys are consumed by the system for
//  focus navigation and should be skipped by our handler.
//  Space/PageUp/PageDown/Escape remain handled.
//
//  Also covers handleCommand (GCKeyboard/pressesBegan path) with
//  throttling and concurrent-navigation protection.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import ReadiumNavigator

@MainActor
final class KeyboardNavigationFKATests: XCTestCase {

    private var mockNavigable: MockKeyboardNavigable!
    private var sut: KeyboardNavigationHandler!

    override func setUp() async throws {
        try await super.setUp()
        mockNavigable = MockKeyboardNavigable()
        mockNavigable.toolbarHidden = true
    }

    override func tearDown() async throws {
        mockNavigable = nil
        sut = nil
        try await super.tearDown()
    }

    // MARK: - FKA: Arrow Keys Skipped

    func testFKA_rightArrow_isNotConsumed() async {
        sut = KeyboardNavigationHandler(
            navigable: mockNavigable,
            isFullKeyboardAccessEnabled: { true }
        )

        let event = KeyEvent(phase: .down, key: .arrowRight, modifiers: [])
        let consumed = await sut.handleKeyEvent(event)

        XCTAssertFalse(consumed, "Arrow keys should NOT be consumed when FKA is enabled")
        XCTAssertFalse(mockNavigable.didCallNavigateRight)
    }

    func testFKA_leftArrow_isNotConsumed() async {
        sut = KeyboardNavigationHandler(
            navigable: mockNavigable,
            isFullKeyboardAccessEnabled: { true }
        )

        let event = KeyEvent(phase: .down, key: .arrowLeft, modifiers: [])
        let consumed = await sut.handleKeyEvent(event)

        XCTAssertFalse(consumed, "Arrow keys should NOT be consumed when FKA is enabled")
        XCTAssertFalse(mockNavigable.didCallNavigateLeft)
    }

    // MARK: - FKA: Non-Arrow Keys Still Handled

    func testFKA_spaceKey_isStillConsumed() async {
        sut = KeyboardNavigationHandler(
            navigable: mockNavigable,
            isFullKeyboardAccessEnabled: { true }
        )

        let event = KeyEvent(phase: .down, key: .space, modifiers: [])
        let consumed = await sut.handleKeyEvent(event)

        XCTAssertTrue(consumed, "Space key should be consumed even with FKA")
        XCTAssertTrue(mockNavigable.didCallNavigateForward)
    }

    func testFKA_escapeKey_isStillConsumed() async {
        sut = KeyboardNavigationHandler(
            navigable: mockNavigable,
            isFullKeyboardAccessEnabled: { true }
        )

        let event = KeyEvent(phase: .down, key: .escape, modifiers: [])
        let consumed = await sut.handleKeyEvent(event)

        XCTAssertTrue(consumed, "Escape key should be consumed even with FKA")
        XCTAssertTrue(mockNavigable.didCallToggleToolbar)
    }

    func testFKA_pageDown_isStillConsumed() async {
        sut = KeyboardNavigationHandler(
            navigable: mockNavigable,
            isFullKeyboardAccessEnabled: { true }
        )

        let event = KeyEvent(phase: .down, key: .pageDown, modifiers: [])
        let consumed = await sut.handleKeyEvent(event)

        XCTAssertTrue(consumed, "PageDown should be consumed even with FKA")
        XCTAssertTrue(mockNavigable.didCallNavigateForward)
    }

    func testFKA_pageUp_isStillConsumed() async {
        sut = KeyboardNavigationHandler(
            navigable: mockNavigable,
            isFullKeyboardAccessEnabled: { true }
        )

        let event = KeyEvent(phase: .down, key: .pageUp, modifiers: [])
        let consumed = await sut.handleKeyEvent(event)

        XCTAssertTrue(consumed, "PageUp should be consumed even with FKA")
        XCTAssertTrue(mockNavigable.didCallNavigateLeft)
    }

    // MARK: - FKA Disabled: Arrow Keys Work Normally

    func testNoFKA_rightArrow_isConsumed() async {
        sut = KeyboardNavigationHandler(
            navigable: mockNavigable,
            isFullKeyboardAccessEnabled: { false }
        )

        let event = KeyEvent(phase: .down, key: .arrowRight, modifiers: [])
        let consumed = await sut.handleKeyEvent(event)

        XCTAssertTrue(consumed, "Arrow keys should be consumed when FKA is disabled")
        XCTAssertTrue(mockNavigable.didCallNavigateRight)
    }

    // MARK: - handleCommand Tests

    func testHandleCommand_goForward_navigatesRight() async {
        sut = KeyboardNavigationHandler(navigable: mockNavigable)

        await sut.handleCommand(.goForward, via: mockNavigable)

        XCTAssertTrue(mockNavigable.didCallNavigateRight)
    }

    func testHandleCommand_goBackward_navigatesLeft() async {
        sut = KeyboardNavigationHandler(navigable: mockNavigable)

        await sut.handleCommand(.goBackward, via: mockNavigable)

        XCTAssertTrue(mockNavigable.didCallNavigateLeft)
    }

    func testHandleCommand_toggleUI_togglesToolbar() async {
        sut = KeyboardNavigationHandler(navigable: mockNavigable)

        await sut.handleCommand(.toggleUI, via: mockNavigable)

        XCTAssertTrue(mockNavigable.didCallToggleToolbar)
    }

    // MARK: - Nil Navigable Safety

    func testHandleKeyEvent_whenNavigableIsNil_returnsFalse() async {
        // Create handler, then let navigable go out of scope
        var tempNavigable: MockKeyboardNavigable? = MockKeyboardNavigable()
        sut = KeyboardNavigationHandler(navigable: tempNavigable!)
        tempNavigable = nil // Weak reference should become nil

        let event = KeyEvent(phase: .down, key: .escape, modifiers: [])
        let consumed = await sut.handleKeyEvent(event)

        XCTAssertFalse(consumed, "Should return false when navigable is nil")
    }
}
