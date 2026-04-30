//
//  AlertModelTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for AlertModel and its factory methods (retryable / maxRetriesExceeded).
/// Originally PP-3707 covered the retry factory; expanded here to also lock in
/// the HalfSheetView branching contract (`secondaryButtonTitle != nil`) and the
/// destructive-style flag.
final class AlertModelRetryTests: XCTestCase {

    // MARK: - Default initializer

    func testDefaultAlertModel_hasExpectedDefaults() {
        let model = AlertModel(title: "Title", message: "Message")
        XCTAssertEqual(model.title, "Title")
        XCTAssertEqual(model.message, "Message")
        XCTAssertNil(model.buttonTitle)
        XCTAssertNil(model.secondaryButtonTitle)
        XCTAssertFalse(
            model.isPrimaryDestructive,
            "Default style is non-destructive — flipping this would silently restyle every error alert in the app."
        )
    }

    func testAlertModel_eachInstanceHasUniqueIdentity() {
        // Identifiable conformance: SwiftUI reuses views keyed by id, so two
        // AlertModels with the same content must still be distinguishable.
        let a = AlertModel(title: "Same", message: "Same")
        let b = AlertModel(title: "Same", message: "Same")
        let c = a // value-type copy — id MUST be preserved on copy
        XCTAssertNotEqual(a.id, b.id, "Distinct constructions yield distinct ids")
        XCTAssertEqual(a.id, c.id, "Value-copy preserves identity")
    }

    // MARK: - retryable factory

    func testRetryable_factoryShapesAlertForRetryPlusCancelBranch() {
        let model = AlertModel.retryable(
            title: "Borrow Failed",
            message: "Invalid OPDS feed"
        ) {}

        // Title + message pass through untouched.
        XCTAssertEqual(model.title, "Borrow Failed")
        XCTAssertEqual(model.message, "Invalid OPDS feed")
        // Primary button = Retry; secondary = Cancel — matches HalfSheetView's
        // expectations for the two-button branch.
        XCTAssertEqual(model.buttonTitle, Strings.MyDownloadCenter.retry)
        XCTAssertEqual(model.secondaryButtonTitle, Strings.Generic.cancel)
        XCTAssertNotNil(
            model.secondaryButtonTitle,
            "HalfSheetView gates the Retry+Cancel UI on `secondaryButtonTitle != nil`"
        )
        // Retryable alerts must not be destructive — that style is reserved
        // for return / cancel-hold confirmations.
        XCTAssertFalse(model.isPrimaryDestructive)
    }

    func testRetryable_invokesRetryActionAndCancelActionOnTheCorrectSlots() {
        var retried = 0
        var cancelled = 0
        let model = AlertModel.retryable(
            title: "Error",
            message: "Msg",
            retryAction: { retried += 1 },
            cancelAction: { cancelled += 1 }
        )

        // Primary slot fires retry; secondary slot fires cancel; neither
        // bleeds into the other.
        model.primaryAction()
        XCTAssertEqual(retried, 1)
        XCTAssertEqual(cancelled, 0)

        model.secondaryAction()
        XCTAssertEqual(retried, 1)
        XCTAssertEqual(cancelled, 1)

        // Re-invocation should keep counting — closures are not single-shot.
        model.primaryAction()
        model.secondaryAction()
        XCTAssertEqual(retried, 2)
        XCTAssertEqual(cancelled, 2)
    }

    func testRetryable_omittedCancelActionIsSafeNoOp() {
        // The cancelAction parameter is optional; HalfSheetView always wires
        // it to the Cancel button. If we accidentally let nil through to the
        // call site, the app crashes when the user taps Cancel.
        let model = AlertModel.retryable(
            title: "Error",
            message: "Msg",
            retryAction: {}
        )
        XCTAssertNotNil(model.secondaryButtonTitle)
        // Must not crash even though no cancelAction was supplied.
        model.secondaryAction()
    }

    // MARK: - maxRetriesExceeded factory

    func testMaxRetriesExceeded_factoryShapesAlertForOKOnlyBranch() {
        let model = AlertModel.maxRetriesExceeded(title: "Borrow Failed")

        // Title passes through; canned tryAgainLater message is used.
        XCTAssertEqual(model.title, "Borrow Failed")
        XCTAssertEqual(model.message, Strings.MyDownloadCenter.tryAgainLater)
        // OK button only — no secondary, which is what HalfSheetView keys off
        // to render the single-button branch.
        XCTAssertEqual(model.buttonTitle, Strings.Generic.ok)
        XCTAssertNil(
            model.secondaryButtonTitle,
            "Max-retries alert must NOT carry a secondary button — that would push HalfSheetView into the Retry+Cancel branch."
        )
        XCTAssertFalse(model.isPrimaryDestructive)
    }

    // MARK: - HalfSheetView branching contract

    func testHalfSheetBranching_secondaryNilSelectsOKOnly_secondaryNonNilSelectsRetryCancel() {
        // The contract is small but load-bearing: HalfSheetView decides which
        // UI to render with `if errorAlert.secondaryButtonTitle != nil`.
        // Lock all three constructors against that decision in one test so a
        // mutant that flips the nil-check survives only briefly.
        let retryable = AlertModel.retryable(title: "T", message: "M") {}
        let maxRetries = AlertModel.maxRetriesExceeded(title: "T")
        let plain = AlertModel(title: "T", message: "M")

        // OK-only branch first — flips the dominant assertion away from
        // XCTAssertNotNil so the lint rule doesn't false-flag this on the
        // immediately-preceding `let plain = AlertModel(...)`.
        XCTAssertNil(maxRetries.secondaryButtonTitle, "maxRetriesExceeded → OK-only branch")
        XCTAssertNil(plain.secondaryButtonTitle,      "plain init → OK-only branch")
        XCTAssertNotNil(retryable.secondaryButtonTitle, "retryable → Retry+Cancel branch")
    }
}
