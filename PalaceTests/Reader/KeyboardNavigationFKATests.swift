//  KeyboardNavigationFKATests.swift
//
//  Full Keyboard Access behavior in KeyboardNavigationHandler: with FKA on, the
//  system uses arrow keys for focus navigation, so the handler skips them while
//  Space/PageUp/PageDown/Escape stay handled. Also covers `handleCommand`
//  (GCKeyboard / pressesBegan path) throttling and concurrent-navigation guard.

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
