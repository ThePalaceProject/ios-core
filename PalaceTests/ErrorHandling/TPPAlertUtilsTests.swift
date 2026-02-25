//
//  TPPAlertUtilsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPAlertUtilsTests: XCTestCase {

    // MARK: - Basic Alert Creation

    func testAlert_titleAndMessage_createsAlert() {
        let alert = TPPAlertUtils.alert(title: "Test Title", message: "Test Message")

        XCTAssertEqual(alert.title, "Test Title")
        XCTAssertEqual(alert.message, "Test Message")
        XCTAssertEqual(alert.preferredStyle, .alert)
    }

    func testAlert_nilTitle_substitutesDefault() {
        let alert = TPPAlertUtils.alert(title: nil, message: "Only message")

        // Implementation substitutes "Alert" for nil/empty titles
        XCTAssertEqual(alert.title, "Alert")
        XCTAssertNotNil(alert.message)
    }

    func testAlert_nilMessage_substitutesEmpty() {
        let alert = TPPAlertUtils.alert(title: "Only title", message: nil)

        XCTAssertNotNil(alert.title)
        // Implementation substitutes "" for nil/empty messages
        XCTAssertEqual(alert.message, "")
    }

    func testAlert_hasOKAction() {
        let alert = TPPAlertUtils.alert(title: "Title", message: "Message")

        XCTAssertGreaterThanOrEqual(alert.actions.count, 1, "Alert should have at least one action")

        let okAction = alert.actions.first(where: { $0.title == "OK" })
        XCTAssertNotNil(okAction, "Alert should have an OK action")
    }

    // MARK: - Alert with Error

    func testAlert_withError_createsAlert() {
        let error = NSError(
            domain: "TestDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Test error message"]
        )

        let alert = TPPAlertUtils.alert(title: "Error", error: error)

        XCTAssertEqual(alert.title, "Error")
        XCTAssertNotNil(alert.message)
    }

    func testAlert_withNilError_createsAlert() {
        let alert = TPPAlertUtils.alert(title: "Error Occurred", error: nil)

        XCTAssertEqual(alert.title, "Error Occurred")
    }

    // MARK: - Alert with Style

    func testAlert_customStyle_usesProvidedStyle() {
        let alert = TPPAlertUtils.alert(
            title: "Destructive",
            message: "Are you sure?",
            style: .destructive
        )

        XCTAssertEqual(alert.title, "Destructive")
        XCTAssertEqual(alert.message, "Are you sure?")
    }

    // MARK: - Alert with Details

    func testAlertWithDetails_hasViewDetailsAction() {
        let alert = TPPAlertUtils.alertWithDetails(
            title: "Borrow Failed",
            message: "Unable to borrow"
        )

        let detailsAction = alert.actions.first(where: { $0.title == "View Error Details" })
        XCTAssertNotNil(detailsAction, "Alert should have a 'View Error Details' action")
    }

    func testAlertWithDetails_hasOKAction() {
        let alert = TPPAlertUtils.alertWithDetails(
            title: "Error",
            message: "Something failed"
        )

        let okAction = alert.actions.first(where: { $0.title == "OK" })
        XCTAssertNotNil(okAction, "Alert should have an OK action")
    }

    func testAlertWithDetails_hasTwoActions() {
        let alert = TPPAlertUtils.alertWithDetails(
            title: "Error",
            message: "Test"
        )

        XCTAssertEqual(alert.actions.count, 2, "Should have OK and View Error Details actions")
    }

    // MARK: - Alert with Details + Problem Document (Regression for PP-3439)

    /// Regression test: when alertWithDetails receives a problem document,
    /// its detail must appear at most once in the final alert message.
    /// Previously, setProblemDocument appended the detail even though the
    /// caller's message already contained it, causing visible duplication.
    func testAlertWithDetails_withProblemDocument_doesNotDuplicateDetail() {
        let serverDetail = "The loan limit for this library has been reached."
        let problemDoc = TPPProblemDocument.fromDictionary([
            "detail": serverDetail
        ])
        let messageWithDetail = "Borrowing Test Book could not be completed.\n\n\(serverDetail)"

        let alert = TPPAlertUtils.alertWithDetails(
            title: "Borrow Failed",
            message: messageWithDetail,
            problemDocument: problemDoc,
            bookIdentifier: "test-id",
            bookTitle: "Test Book"
        )

        let occurrences = alert.message?
            .components(separatedBy: serverDetail).count ?? 0
        // components(separatedBy:) returns N+1 parts for N occurrences
        XCTAssertEqual(
            occurrences - 1, 1,
            "Problem document detail should appear exactly once, found \(occurrences - 1)"
        )
    }

    /// Integration test: exercises the same buildBorrowErrorMessage →
    /// alertWithDetails pipeline used by showBorrowError to ensure the
    /// full call chain never duplicates the problem document detail.
    func testBorrowErrorPipeline_doesNotDuplicateProblemDocDetail() {
        let serverDetail = "An internal error occurred on the server."
        let problemDoc = TPPProblemDocument.fromDictionary([
            "detail": serverDetail
        ])

        let message = MyBooksDownloadCenter.buildBorrowErrorMessage(
            for: "Test Book",
            error: .network(.serverError),
            problemDocument: problemDoc
        )

        let alert = TPPAlertUtils.alertWithDetails(
            title: "Borrow Failed",
            message: message,
            problemDocument: problemDoc,
            bookIdentifier: "test-id",
            bookTitle: "Test Book"
        )

        let occurrences = alert.message?
            .components(separatedBy: serverDetail).count ?? 0
        XCTAssertEqual(
            occurrences - 1, 1,
            "Full borrow pipeline should show detail exactly once, found \(occurrences - 1)"
        )
    }

    /// Ensures alertWithDetails still shows the problem document detail when
    /// the message does NOT already include it (e.g. a caller that passes a
    /// plain message alongside a problem document).
    func testAlertWithDetails_plainMessageWithProblemDoc_includesDetail() {
        let serverDetail = "License expired"
        let problemDoc = TPPProblemDocument.fromDictionary([
            "detail": serverDetail
        ])

        let alert = TPPAlertUtils.alertWithDetails(
            title: "Error",
            message: "Something went wrong.",
            problemDocument: problemDoc
        )

        XCTAssertTrue(
            alert.message?.contains("Something went wrong.") == true,
            "Original message must be present"
        )
    }

    // MARK: - Problem Document

    func testSetProblemDocument_appendsToMessage() {
        let alert = TPPAlertUtils.alert(title: "Error", message: "Base message")
        let problemDoc = TPPProblemDocument.fromDictionary([
            "detail": "Detailed server error message"
        ])

        TPPAlertUtils.setProblemDocument(controller: alert, document: problemDoc, append: true)

        XCTAssertNotNil(alert.message)
        if let message = alert.message {
            XCTAssertTrue(message.contains("Base message"), "Should keep original message")
        }
    }

    func testSetProblemDocument_replacesMessage() {
        let alert = TPPAlertUtils.alert(title: "Error", message: "Original")
        let problemDoc = TPPProblemDocument.fromDictionary([
            "detail": "Server says: loan limit reached"
        ])

        TPPAlertUtils.setProblemDocument(controller: alert, document: problemDoc, append: false)

        XCTAssertNotNil(alert.message)
    }

    func testSetProblemDocument_nilController_doesNotCrash() {
        let problemDoc = TPPProblemDocument.fromDictionary([
            "detail": "Error detail"
        ])

        // Should not crash
        TPPAlertUtils.setProblemDocument(controller: nil, document: problemDoc, append: true)
    }

    func testSetProblemDocument_nilDocument_doesNotCrash() {
        let alert = TPPAlertUtils.alert(title: "Error", message: "Message")

        // Should not crash
        TPPAlertUtils.setProblemDocument(controller: alert, document: nil, append: true)
    }

    // MARK: - Alert Stacking Safety (Regression for Crashlytics fe741015)

    /// Regression test for Crashlytics issue fe741015: NSInternalInconsistencyException
    /// "A view controller not containing an alert controller was asked for its
    /// contained alert controller."
    ///
    /// The crash occurred when a user tapped "Borrow" multiple times on a book with
    /// no licenses. Each failure triggered an error alert. The second alert presentation
    /// found the first UIAlertController via topMostViewController traversal and tried
    /// to present from it, causing the crash.
    ///
    /// Fix: topMostViewController stops at UIAlertControllers instead of traversing into them,
    /// allowing the existing "another alert is already visible" guard to properly skip.
    func testCrashlyticsFE741015_PresentAlertWhileAlertShowing_DoesNotCrash() {
        // Arrange: Create a root view controller with a window
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        let rootVC = UIViewController()
        window.rootViewController = rootVC
        window.makeKeyAndVisible()

        // Present the first alert (simulating first borrow failure)
        let firstAlert = TPPAlertUtils.alert(title: "Error", message: "No licenses available")
        let presentExpectation = expectation(description: "First alert presented")
        rootVC.present(firstAlert, animated: false) {
            presentExpectation.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // Verify the first alert is presented
        XCTAssertNotNil(rootVC.presentedViewController)
        XCTAssertTrue(rootVC.presentedViewController is UIAlertController)

        // Act: Try to present a second alert (simulating second borrow failure)
        // This should NOT crash - previously it would crash with
        // NSInternalInconsistencyException because topMostViewController
        // would traverse into the first alert and try to present from it.
        let secondAlert = TPPAlertUtils.alert(title: "Error", message: "No licenses available (2nd attempt)")

        // Use presentFromViewControllerOrNil with viewController = rootVC
        // (the specific VC path, not the topMostViewController path)
        let secondExpectation = expectation(description: "Second alert handled without crash")

        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: secondAlert,
            viewController: rootVC,
            animated: false,
            completion: {
                secondExpectation.fulfill()
            }
        )
        waitForExpectations(timeout: 2.0)

        // The second alert should have been skipped (first is still showing)
        // If we got here, no crash occurred
        XCTAssertTrue(rootVC.presentedViewController is UIAlertController,
                      "First alert should still be presented")

        // Cleanup
        let dismissExpectation = expectation(description: "Alert dismissed")
        rootVC.dismiss(animated: false) {
            dismissExpectation.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        window.isHidden = true
    }

    /// Tests the retry mechanism: when the first alert is dismissed after a short
    /// delay, the second alert should eventually be presented via retry logic.
    /// Previously, the second alert would simply be dropped.
    func testRetryPresentation_AfterFirstAlertDismisses_PresentsSecond() {
        // Arrange
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        let rootVC = UIViewController()
        window.rootViewController = rootVC
        window.makeKeyAndVisible()

        // Present first alert
        let firstAlert = TPPAlertUtils.alert(title: "Error", message: "First error")
        let firstPresented = expectation(description: "First alert presented")
        rootVC.present(firstAlert, animated: false) {
            firstPresented.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // Schedule the second alert — retry logic should queue it
        let secondAlert = TPPAlertUtils.alert(title: "Error", message: "Second error")
        let secondHandled = expectation(description: "Second alert handler called")

        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: secondAlert,
            viewController: rootVC,
            animated: false,
            completion: {
                secondHandled.fulfill()
            }
        )

        // Dismiss the first alert after a brief delay, allowing retry to succeed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            rootVC.dismiss(animated: false, completion: nil)
        }

        // The retry logic uses exponential backoff starting at 0.4s, so within ~1s
        // the first alert should be dismissed and the retry should succeed
        waitForExpectations(timeout: 5.0)

        // Cleanup
        let dismissExpectation = expectation(description: "Dismissed")
        rootVC.dismiss(animated: false) {
            dismissExpectation.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        window.isHidden = true
    }

    /// Verifies the retry limit: after maxAlertRetries, the alert is dropped with completion called.
    func testRetryPresentation_ExceedsMaxRetries_DropsAlertWithCompletion() {
        // Arrange: present an alert that will NEVER be dismissed
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        let rootVC = UIViewController()
        window.rootViewController = rootVC
        window.makeKeyAndVisible()

        let blockingAlert = TPPAlertUtils.alert(title: "Blocking", message: "I stay forever")
        let blockingPresented = expectation(description: "Blocking alert presented")
        rootVC.present(blockingAlert, animated: false) {
            blockingPresented.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // Try to present a second alert — retries will all fail since blocking alert stays
        let droppedAlert = TPPAlertUtils.alert(title: "Dropped", message: "I will be dropped")
        let completionCalled = expectation(description: "Completion called after max retries")

        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: droppedAlert,
            viewController: rootVC,
            animated: false,
            completion: {
                completionCalled.fulfill()
            }
        )

        // Exponential backoff: 0.4s + 0.8s + 1.6s = 2.8s for 3 retries, plus some buffer
        waitForExpectations(timeout: 8.0)

        // The blocking alert should still be the presented one (not the dropped one)
        XCTAssertTrue(rootVC.presentedViewController is UIAlertController)
        XCTAssertEqual((rootVC.presentedViewController as? UIAlertController)?.message, "I stay forever",
                       "The blocking alert should still be visible; dropped alert should not have replaced it")

        // Cleanup
        let dismissExpectation = expectation(description: "Dismissed")
        rootVC.dismiss(animated: false) {
            dismissExpectation.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        window.isHidden = true
    }

    /// Tests that presenting an alert when no alert is showing still works correctly.
    func testPresentAlert_WhenNoAlertShowing_PresentsSuccessfully() {
        // Arrange
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        let rootVC = UIViewController()
        window.rootViewController = rootVC
        window.makeKeyAndVisible()

        let alert = TPPAlertUtils.alert(title: "Test", message: "Test Message")

        // Act
        let expectation = self.expectation(description: "Alert presented")
        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: alert,
            viewController: rootVC,
            animated: false,
            completion: {
                expectation.fulfill()
            }
        )
        waitForExpectations(timeout: 2.0)

        // Assert
        XCTAssertNotNil(rootVC.presentedViewController)
        XCTAssertTrue(rootVC.presentedViewController is UIAlertController)

        // Cleanup
        let dismissExpectation = self.expectation(description: "Dismissed")
        rootVC.dismiss(animated: false) {
            dismissExpectation.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        window.isHidden = true
    }
}
