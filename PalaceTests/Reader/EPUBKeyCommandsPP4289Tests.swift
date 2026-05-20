//
//  EPUBKeyCommandsPP4289Tests.swift
//  PalaceTests
//
//  PP-4289 regression — Mac/iPad-on-Mac keyboard escape hatch.
//
//  Before this fix, opening a book in Reader2 on Apple Silicon Mac as
//  "Designed for iPad" trapped the user: tap-to-toggle-toolbar did not
//  fire on mouse-click, Esc had no visible effect, and the default
//  Cmd+W (close-window) closed the *entire Palace app* — Palace is a
//  single-scene iPad app, so closing the only window dismisses the app.
//
//  The fix is purely additive: two new UIKeyCommand bindings to existing
//  reader actions (closeEPUB, presentUserSettings). The arrow / space /
//  Esc bindings are unchanged.
//
//  These assertions are deliberately narrow — they verify the array
//  *contains* the right (input, modifierFlags) pairs and that every
//  binding wants priority over system behavior. They do not exercise
//  the runtime UIKit dispatch path; that needs a UI test.
//

import XCTest
import UIKit
@testable import Palace

@MainActor
final class EPUBKeyCommandsPP4289Tests: XCTestCase {

    private var commands: [UIKeyCommand] { TPPEPUBViewController.readerKeyCommands }

    // MARK: - Cmd+W binding

    /// PP-4289 critical: without this binding, Cmd+W in iPad-on-Mac closes
    /// the entire Palace window/app instead of dismissing the reader.
    func testReaderKeyCommands_includesCmdW_routedToCloseReader() {
        let cmdW = commands.first { $0.input == "w" && $0.modifierFlags == .command }
        XCTAssertNotNil(cmdW, "Cmd+W must be bound — PP-4289 escape hatch")
        XCTAssertEqual(cmdW?.action, Selector(("keyCommandCloseReader")))
        XCTAssertTrue(cmdW?.wantsPriorityOverSystemBehavior ?? false,
                      "Cmd+W must claim priority so iPadOS doesn't dispatch close-window first")
    }

    // MARK: - Cmd+, binding

    func testReaderKeyCommands_includesCmdComma_routedToSettings() {
        let cmdComma = commands.first { $0.input == "," && $0.modifierFlags == .command }
        XCTAssertNotNil(cmdComma, "Cmd+, must be bound — PP-4289 settings shortcut")
        XCTAssertEqual(cmdComma?.action, Selector(("keyCommandShowSettings")))
    }

    // MARK: - Existing bindings preserved

    func testReaderKeyCommands_preservesArrowLeftRightSpaceShiftSpaceEscape() {
        let leftArrow = commands.first { $0.input == UIKeyCommand.inputLeftArrow && $0.modifierFlags == [] }
        let rightArrow = commands.first { $0.input == UIKeyCommand.inputRightArrow && $0.modifierFlags == [] }
        let space = commands.first { $0.input == " " && $0.modifierFlags == [] }
        let shiftSpace = commands.first { $0.input == " " && $0.modifierFlags == .shift }
        let escape = commands.first { $0.input == UIKeyCommand.inputEscape && $0.modifierFlags == [] }

        XCTAssertNotNil(leftArrow, "Existing arrow-left binding must not regress")
        XCTAssertNotNil(rightArrow, "Existing arrow-right binding must not regress")
        XCTAssertNotNil(space, "Existing space (forward) binding must not regress")
        XCTAssertNotNil(shiftSpace, "Existing shift+space (back) binding must not regress")
        XCTAssertNotNil(escape, "Existing Escape (toggle UI) binding must not regress")
    }

    // MARK: - Priority invariant

    func testReaderKeyCommands_everyBindingClaimsPriorityOverSystem() {
        for command in commands {
            XCTAssertTrue(
                command.wantsPriorityOverSystemBehavior,
                "\(command.input ?? "?") must claim priority over system behavior — iPadOS / iPad-on-Mac focus engine and Mac window manager will otherwise eat the event"
            )
        }
    }
}
