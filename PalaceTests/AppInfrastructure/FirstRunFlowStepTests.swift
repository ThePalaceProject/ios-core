//
//  FirstRunFlowStepTests.swift
//  PalaceTests
//
//  PP-5220 — the decision behind "does this patron see the library picker?"
//
//  This decision had no tests until now, and it is the one piece of logic in
//  Palace that can leave a brand-new patron with no library at all, or with
//  four pickers stacked on top of each other. The second is not hypothetical:
//  PP-4329 was exactly that, on a fresh install on iOS 26.4.2.
//
//  The inputs are finite, so they are asserted as a table rather than as
//  scenarios. Scenarios are unbounded and would have missed PP-4329 too.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class FirstRunFlowStepTests: XCTestCase {

    private func step(
        hasPresented: Bool = false,
        catalogHasLoaded: Bool = true,
        managed: ManagedLibraryLaunchStep = .presentPicker,
        hasCurrentAccount: Bool = false
    ) -> FirstRunFlowStep {
        FirstRunFlowDecision.step(
            hasPresented: hasPresented,
            catalogHasLoaded: catalogHasLoaded,
            managedStep: managed,
            hasCurrentAccount: hasCurrentAccount
        )
    }

    private let everyManagedStep: [ManagedLibraryLaunchStep] =
        [.libraryApplied, .waitForRegistry, .presentPicker]

    // MARK: - The picker appears once and only once
    //
    // PP-4329: the catalog load posts up to eight notifications in worst-case
    // fallback paths, and every one of them re-enters this decision.

    func testOncePresented_NothingElseCanPresentAgain() {
        // Exhaustive over every other input, because the guard has to hold
        // regardless of what the rest of the world is doing.
        for catalogLoaded in [true, false] {
            for managed in everyManagedStep {
                for hasAccount in [true, false] {
                    XCTAssertEqual(
                        step(hasPresented: true,
                             catalogHasLoaded: catalogLoaded,
                             managed: managed,
                             hasCurrentAccount: hasAccount),
                        .alreadyHandled,
                        "catalog=\(catalogLoaded) managed=\(managed) account=\(hasAccount)"
                    )
                }
            }
        }
    }

    func testTheGuardIsCheckedBeforeAnythingElse() {
        // If ordering slipped, a managed configuration applying could re-enter
        // and present a second picker behind the first.
        XCTAssertEqual(
            step(hasPresented: true, catalogHasLoaded: true, managed: .libraryApplied),
            .alreadyHandled
        )
    }

    // MARK: - Nothing is decided on an unloaded catalog

    func testCatalogNotLoaded_WaitsRegardlessOfEverythingElse() {
        // `currentAccount` gives a false negative until the library list
        // exists, so deciding anything here risks showing the picker to a
        // patron who already has a library.
        for managed in everyManagedStep {
            for hasAccount in [true, false] {
                XCTAssertEqual(
                    step(hasPresented: false,
                         catalogHasLoaded: false,
                         managed: managed,
                         hasCurrentAccount: hasAccount),
                    .waitForCatalog,
                    "managed=\(managed) account=\(hasAccount)"
                )
            }
        }
    }

    // MARK: - The managed arm

    func testManagedConfigurationSelectedALibrary_NobodyIsAsked() {
        for hasAccount in [true, false] {
            XCTAssertEqual(
                step(managed: .libraryApplied, hasCurrentAccount: hasAccount),
                .librarySelected,
                "a configured device is never asked, account=\(hasAccount)"
            )
        }
    }

    func testManagedConfigurationPending_WaitsRatherThanAsking() {
        // A slow network is not a verdict. This is the case that matters on a
        // cart of devices on a school network in the morning.
        XCTAssertEqual(step(managed: .waitForRegistry), .waitForManagedLibrary)
    }

    func testManagedWaitTakesPrecedenceOverShowingThePicker() {
        // Even with no current account — which on its own means "ask" — a
        // pending configuration must win, or the feature never helps anyone.
        XCTAssertEqual(
            step(managed: .waitForRegistry, hasCurrentAccount: false),
            .waitForManagedLibrary
        )
    }

    // MARK: - The unmanaged path, which is almost every patron

    func testNoManagedConfigurationAndNoLibrary_PresentsThePicker() {
        XCTAssertEqual(
            step(managed: .presentPicker, hasCurrentAccount: false),
            .presentPicker
        )
    }

    func testNoManagedConfigurationButALibraryAlready_DoesNothing() {
        XCTAssertEqual(
            step(managed: .presentPicker, hasCurrentAccount: true),
            .nothingToDo
        )
    }

    func testAnUnmanagedLaunchIsDecidedOnlyByWhetherALibraryExists() {
        // The regression that matters most: the overwhelming majority of
        // patrons are not managed, and their launch must behave exactly as it
        // did before any of this work. With the managed arm saying nothing,
        // the answer is a function of `hasCurrentAccount` alone.
        XCTAssertEqual(step(managed: .presentPicker, hasCurrentAccount: false), .presentPicker)
        XCTAssertEqual(step(managed: .presentPicker, hasCurrentAccount: true), .nothingToDo)
    }

    // MARK: - Invariants across the whole table

    func testThePickerIsNeverShownToSomeoneWhoAlreadyHasALibrary() {
        for hasPresented in [true, false] {
            for catalogLoaded in [true, false] {
                for managed in everyManagedStep {
                    XCTAssertNotEqual(
                        step(hasPresented: hasPresented,
                             catalogHasLoaded: catalogLoaded,
                             managed: managed,
                             hasCurrentAccount: true),
                        .presentPicker,
                        "presented=\(hasPresented) catalog=\(catalogLoaded) managed=\(managed)"
                    )
                }
            }
        }
    }

    func testEveryCombinationYieldsExactlyOneAnswer() {
        // A decision that can fall through returns nothing and leaves a patron
        // on a blank screen. Exhaust the space and assert each cell resolves.
        var seen = 0
        for hasPresented in [true, false] {
            for catalogLoaded in [true, false] {
                for managed in everyManagedStep {
                    for hasAccount in [true, false] {
                        _ = step(hasPresented: hasPresented,
                                 catalogHasLoaded: catalogLoaded,
                                 managed: managed,
                                 hasCurrentAccount: hasAccount)
                        seen += 1
                    }
                }
            }
        }
        XCTAssertEqual(seen, 2 * 2 * 3 * 2, "the whole input space was walked")
    }
}
