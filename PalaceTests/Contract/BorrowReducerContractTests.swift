//
//  BorrowReducerContractTests.swift
//  PalaceTests
//
//  First contract-snapshot test. Reducer is a pure function over an inout
//  BorrowState — easy to record + lock without dependency mocking. This is the
//  "happy path" demonstration of the contract pattern; richer contracts on
//  BorrowOperation, BookReturnService, and DownloadStartCoordinator are the
//  follow-up. See PalaceTests/Contract/README.md for the rationale.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class BorrowReducerContractTests: XCTestCase {

    /// Records the state-transition contract for every (registry-state, prior-state)
    /// pair the reducer is documented to handle. If a future refactor changes
    /// which acquire-side flags get cleared on a given transition, this snapshot
    /// drifts and fails.
    ///
    /// This is the safety net F-011 would have hit at PR time: BorrowReducer's
    /// missing `.downloadNeeded` arm produced an observable
    /// "acquire flags stayed set on .downloadNeeded transition" — exactly the
    /// kind of behavior change a state-transition snapshot pins.
    func test_registryStateChanged_transitionContract() {
        let log = CallLog()
        // Acquire-side flags include the .get button (Borrow), .download (manual),
        // .retry (after failure), .reserve (Place Hold). Pre-populate the bag with
        // all four so the reducer's clear-on-transition behavior is fully observable.
        let preFlags: Set<BookButtonType> = [.get, .download, .retry, .reserve, .returning]
        let registryStates: [TPPBookState] = [
            .unregistered,
            .downloadNeeded,
            .downloading,
            .downloadFailed,
            .downloadSuccessful,
            .used,
            .holding,
            .returning,
            .unsupported,
            .SAMLStarted,
        ]
        for newState in registryStates {
            var state = BorrowState(
                bookState: .unregistered,
                downloadProgress: 0,
                processingButtons: preFlags,
                isManagingHold: false,
                showHalfSheet: true
            )
            _ = BorrowReducer.reduce(&state, .registryStateChanged(newState))
            log.record(
                "registryStateChanged",
                args: [
                    "input.priorBookState": "unregistered",
                    "input.newRegistryState": "\(newState.stringValue())",
                    "output.bookState": "\(state.bookState.stringValue())",
                    "output.processingButtons": sortedFlags(state.processingButtons),
                    "output.isManagingHold": state.isManagingHold,
                    "output.showHalfSheet": state.showHalfSheet,
                    "output.localBookStateOverride": state.localBookStateOverride.map { $0.stringValue() } ?? "nil",
                ]
            )
        }
        ContractSnapshot.assert(log, named: "registryStateChanged_allCases")
    }

    /// User-action transitions (download confirmed / return confirmed /
    /// cancel-tapped / manage-hold-tapped). Same shape as above — for each
    /// action, record the resulting state slice.
    func test_userActions_transitionContract() {
        let log = CallLog()
        let actions: [(String, BorrowAction)] = [
            ("downloadStartConfirmed", .downloadStartConfirmed),
            ("returnStartConfirmed", .returnStartConfirmed),
            ("cancelTapped", .cancelTapped),
            ("manageHoldTapped", .manageHoldTapped),
            ("signInCancelled", .signInCancelled),
        ]
        for (name, action) in actions {
            var state = BorrowState(
                bookState: .unregistered,
                downloadProgress: 0,
                processingButtons: [.get, .download, .retry, .returning, .reserve],
                isManagingHold: false,
                showHalfSheet: true
            )
            _ = BorrowReducer.reduce(&state, action)
            log.record(
                name,
                args: [
                    "output.bookState": "\(state.bookState.stringValue())",
                    "output.processingButtons": sortedFlags(state.processingButtons),
                    "output.isManagingHold": state.isManagingHold,
                    "output.showHalfSheet": state.showHalfSheet,
                    "output.downloadProgress": state.downloadProgress,
                    "output.localBookStateOverride": state.localBookStateOverride.map { $0.stringValue() } ?? "nil",
                ]
            )
        }
        ContractSnapshot.assert(log, named: "userActions_allKinds")
    }

    /// Deterministic stringification of the flag set — sets have no order, so
    /// snapshot the alphabetized rawValue list to keep the contract stable.
    private func sortedFlags(_ flags: Set<BookButtonType>) -> String {
        flags
            .map { String(describing: $0) }
            .sorted()
            .joined(separator: ",")
    }
}
