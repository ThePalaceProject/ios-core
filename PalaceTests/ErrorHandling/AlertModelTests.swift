//
//  AlertModelTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for AlertModel factory methods — PP-3707
final class AlertModelTests: XCTestCase {

    // MARK: - Default AlertModel

    func testDefaultAlertModel_hasExpectedDefaults() {
        let model = AlertModel(title: "Title", message: "Message")
        XCTAssertEqual(model.title, "Title")
        XCTAssertEqual(model.message, "Message")
        XCTAssertNil(model.buttonTitle)
        XCTAssertNil(model.secondaryButtonTitle)
    }

    func testAlertModel_isIdentifiable() {
        let model1 = AlertModel(title: "A", message: "B")
        let model2 = AlertModel(title: "A", message: "B")
        XCTAssertNotEqual(model1.id, model2.id, "Each AlertModel should have a unique id")
    }

    // MARK: - Retryable Factory

    func testRetryable_setsRetryButtonTitle() {
        let model = AlertModel.retryable(title: "Error", message: "Something went wrong") {}
        XCTAssertEqual(model.buttonTitle, Strings.MyDownloadCenter.retry)
    }

    func testRetryable_setsCancelAsSecondaryButton() {
        let model = AlertModel.retryable(title: "Error", message: "Something went wrong") {}
        XCTAssertEqual(model.secondaryButtonTitle, Strings.Generic.cancel)
    }

    func testRetryable_hasNonNilSecondaryButtonTitle() {
        let model = AlertModel.retryable(title: "Error", message: "Msg") {}
        XCTAssertNotNil(model.secondaryButtonTitle, "Retryable alerts must have secondaryButtonTitle for HalfSheetView branching")
    }

    func testRetryable_executesRetryAction() {
        var retried = false
        let model = AlertModel.retryable(title: "Error", message: "Msg") {
            retried = true
        }
        model.primaryAction()
        XCTAssertTrue(retried)
    }

    func testRetryable_executesCancelAction() {
        var cancelled = false
        let model = AlertModel.retryable(title: "Error", message: "Msg", retryAction: {}, cancelAction: {
            cancelled = true
        })
        model.secondaryAction()
        XCTAssertTrue(cancelled)
    }

    func testRetryable_preservesTitleAndMessage() {
        let model = AlertModel.retryable(title: "Borrow Failed", message: "Invalid OPDS feed") {}
        XCTAssertEqual(model.title, "Borrow Failed")
        XCTAssertEqual(model.message, "Invalid OPDS feed")
    }

    // MARK: - Max Retries Exceeded Factory

    func testMaxRetriesExceeded_setsOKButton() {
        let model = AlertModel.maxRetriesExceeded(title: "Error")
        XCTAssertEqual(model.buttonTitle, Strings.Generic.ok)
    }

    func testMaxRetriesExceeded_showsTryAgainLaterMessage() {
        let model = AlertModel.maxRetriesExceeded(title: "Error")
        XCTAssertEqual(model.message, Strings.MyDownloadCenter.tryAgainLater)
    }

    func testMaxRetriesExceeded_hasNoSecondaryButton() {
        let model = AlertModel.maxRetriesExceeded(title: "Error")
        XCTAssertNil(model.secondaryButtonTitle, "Max retries alert should have no secondary button")
    }

    func testMaxRetriesExceeded_preservesTitle() {
        let model = AlertModel.maxRetriesExceeded(title: "Borrow Failed")
        XCTAssertEqual(model.title, "Borrow Failed")
    }

    // MARK: - HalfSheetView Branching Logic

    /// The HalfSheetView uses `secondaryButtonTitle != nil` to decide whether to show
    /// Retry+Cancel or OK-only. Verify that the factory methods produce the correct signals.
    func testRetryable_triggersRetryBranch() {
        let model = AlertModel.retryable(title: "T", message: "M") {}
        // The HalfSheetView checks: errorAlert.secondaryButtonTitle != nil
        XCTAssertNotNil(model.secondaryButtonTitle, "Retryable should trigger the Retry+Cancel branch")
    }

    func testMaxRetriesExceeded_triggersOKBranch() {
        let model = AlertModel.maxRetriesExceeded(title: "T")
        // The HalfSheetView checks: errorAlert.secondaryButtonTitle != nil
        XCTAssertNil(model.secondaryButtonTitle, "Max retries should trigger the OK-only branch")
    }

    func testDefaultModel_triggersOKBranch() {
        let model = AlertModel(title: "T", message: "M")
        XCTAssertNil(model.secondaryButtonTitle, "Default model should trigger the OK-only branch")
    }
}
