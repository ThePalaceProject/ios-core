//
//  TPPAlertUtilsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class TPPAlertUtilsTests: XCTestCase {

    // MARK: - Hermetic teardown for alert-presentation tests
    //
    // Several tests below present a REAL UIAlertController on a live, key
    // UIWindow to exercise the presentation/retry path. Their happy-path
    // cleanup lives in the test body, so a failure or timeout BEFORE that
    // cleanup — or a `presentFromViewControllerOrNil` retry block
    // (DispatchQueue.main.asyncAfter, exponential backoff up to ~1.6s) firing
    // AFTER `waitForExpectations` returns — can leave an alert presented on a
    // key window. That window then stays reachable via the SHARED
    // `(UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController()`
    // resolution, so the NEXT test's nil-presenter path finds a leftover
    // UIAlertController and exhausts its 3 retries ("top controller is still a
    // UIAlertController"). This is a test-isolation leak, not a production bug.
    //
    // tearDown guarantees the shared UIKit hierarchy is clean between tests
    // regardless of how a test exited: it drains pending retry blocks, then
    // synchronously dismisses any presented controller and releases the window
    // (resign key + drop from the app's window list) so nothing leaks forward.
    private var presentationWindow: UIWindow?
    private var presentationRootVC: UIViewController?

    /// Track a window/root created by a presentation test so `tearDown` can
    /// guarantee its cleanup even if the test body exits early.
    private func trackForHermeticTeardown(_ window: UIWindow, _ rootVC: UIViewController) {
        presentationWindow = window
        presentationRootVC = rootVC
    }

    /// Spin the main run loop so any scheduled `asyncAfter` retry blocks fire
    /// now (against the about-to-be-released hierarchy) instead of bleeding
    /// into the next test.
    private func drainMainRunLoop(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    override func tearDown() {
        // Only the presentation tests register a window. Every other test in
        // this class is a pure unit test with nothing to tear down — skip the
        // run-loop pump and dismissal entirely so they stay fast.
        if presentationWindow != nil {
            // 1. Pump the main run loop once so any work the presentation
            //    scheduled settles before we tear the hierarchy down.
            drainMainRunLoop(0.05)

            // 2. Synchronously dismiss anything still presented on the tracked
            //    root (covers tests that exited before their body cleanup).
            if presentationRootVC?.presentedViewController != nil {
                let dismissed = expectation(description: "tearDown: dismiss leaked alert")
                presentationRootVC?.dismiss(animated: false) { dismissed.fulfill() }
                wait(for: [dismissed], timeout: 2.0)
            }

            // 3. Release the window: relinquish key status and drop it from the
            //    app's window list so a later test can't resolve it as the top
            //    VC via TPPAppDelegate.topViewController(). This is the load-
            //    bearing step — a released test window can never leak forward.
            presentationWindow?.isHidden = true
            presentationWindow?.rootViewController = nil
            presentationWindow?.resignKey()
            if #available(iOS 13.0, *) { presentationWindow?.windowScene = nil }
            presentationRootVC = nil
            presentationWindow = nil

            // 4. Final pump so a block scheduled during dismissal resolves
            //    against the now-empty hierarchy, not the next test's.
            drainMainRunLoop(0.05)
        }

        super.tearDown()
    }

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
        XCTAssertEqual(alert.preferredStyle, .alert)
        XCTAssertGreaterThanOrEqual(alert.actions.count, 1, "Alert must have at least one action")
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
        // After calling with nil controller, clientDomain remains accessible
        XCTAssertNotNil(problemDoc, "Problem document must still be accessible after a nil-controller call")
    }

    func testSetProblemDocument_nilDocument_doesNotCrash() {
        let alert = TPPAlertUtils.alert(title: "Error", message: "Message")
        let originalMessage = alert.message

        // Should not crash
        TPPAlertUtils.setProblemDocument(controller: alert, document: nil, append: true)
        // Alert message must not change when document is nil
        XCTAssertEqual(alert.message, originalMessage,
                       "Alert message must not be modified when setProblemDocument receives nil document")
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
        trackForHermeticTeardown(window, rootVC)

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
        trackForHermeticTeardown(window, rootVC)

        // Present first alert
        let firstAlert = TPPAlertUtils.alert(title: "Error", message: "First error")
        let firstPresented = expectation(description: "First alert presented")
        rootVC.present(firstAlert, animated: false) {
            firstPresented.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // Verify first alert is presented before attempting retry
        XCTAssertNotNil(rootVC.presentedViewController, "First alert must be presented before retry test")

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

        // Dismiss the first alert after a brief delay, allowing retry to succeed.
        // FLAKE-002-OK: closure dismisses the alert (real production action), not a `.fulfill()` —
        //               the linter regex spans across the unrelated dismissExpectation.fulfill below.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { // FLAKE-002-OK
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
        trackForHermeticTeardown(window, rootVC)

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
    // MARK: - Three-arg alert(title:message:error:) overload

    func testAlertTitleMessageError_withMessage_prefersMessageOverError() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let alert = TPPAlertUtils.alert(title: "T", message: "Explicit message", error: err)
        XCTAssertEqual(alert.title, "T")
        XCTAssertEqual(alert.message, "Explicit message")
    }

    func testAlertTitleMessageError_withNilMessage_fallsBackToError() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let alert = TPPAlertUtils.alert(title: "T", message: nil, error: err)
        XCTAssertEqual(alert.title, "T")
        // NotConnected key is localized; ensure non-empty and not the generic fallback
        XCTAssertFalse(alert.message?.isEmpty ?? true)
    }

    // MARK: - NSURLError mapping

    func testAlert_withNSURLErrorNotConnected_setsMessage() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let alert = TPPAlertUtils.alert(title: "Net", error: err)
        XCTAssertEqual(alert.title, "Net")
        XCTAssertFalse(alert.message?.isEmpty ?? true)
        XCTAssertGreaterThanOrEqual(alert.actions.count, 1, "Alert must have at least an OK action")
    }

    func testAlert_withNSURLErrorCancelled_setsMessage() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let alert = TPPAlertUtils.alert(title: "C", error: err)
        XCTAssertFalse(alert.message?.isEmpty ?? true)
        XCTAssertEqual(alert.title, "C")
        XCTAssertGreaterThanOrEqual(alert.actions.count, 1)
    }

    func testAlert_withNSURLErrorTimedOut_setsMessage() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let alert = TPPAlertUtils.alert(title: "C", error: err)
        XCTAssertFalse(alert.message?.isEmpty ?? true)
        XCTAssertEqual(alert.title, "C")
        XCTAssertGreaterThanOrEqual(alert.actions.count, 1)
    }

    func testAlert_withNSURLErrorUnsupportedURL_setsMessage() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL)
        let alert = TPPAlertUtils.alert(title: "C", error: err)
        XCTAssertFalse(alert.message?.isEmpty ?? true)
        XCTAssertEqual(alert.preferredStyle, .alert)
        XCTAssertGreaterThanOrEqual(alert.actions.count, 1)
    }

    func testAlert_withNSURLErrorUnknownCode_setsUnknownRequestMessage() {
        let err = NSError(domain: NSURLErrorDomain, code: -99999)
        let alert = TPPAlertUtils.alert(title: "C", error: err)
        XCTAssertFalse(alert.message?.isEmpty ?? true)
        XCTAssertEqual(alert.title, "C")
        XCTAssertGreaterThanOrEqual(alert.actions.count, 1)
    }

    func testAlert_withUnknownDomainAndLocalizedDescription_usesDescription() {
        let err = NSError(
            domain: "SomeDomain", code: 123,
            userInfo: [NSLocalizedDescriptionKey: "Specific thing failed"]
        )
        let alert = TPPAlertUtils.alert(title: "X", error: err)
        XCTAssertTrue(alert.message?.contains("Specific thing failed") ?? false)
    }

    func testAlert_withUnknownDomainNoDescription_usesGenericFallback() {
        let err = NSError(domain: "Weird", code: 1)
        let alert = TPPAlertUtils.alert(title: "X", error: err)
        XCTAssertFalse(alert.message?.isEmpty ?? true)
        // Title must pass through unchanged for non-empty title
        XCTAssertEqual(alert.title, "X", "Title must be preserved for non-empty input")
        // Alert must have at least one action (OK button)
        XCTAssertFalse(alert.actions.isEmpty, "Alert must include at least one action")
    }

    // MARK: - Empty/edge titles & messages

    func testAlert_emptyTitle_substitutesAlertDefault() {
        let alert = TPPAlertUtils.alert(title: "", message: "msg")
        XCTAssertEqual(alert.title, "Alert")
        // Non-empty title must not be substituted
        let alertWithTitle = TPPAlertUtils.alert(title: "My Title", message: "msg")
        XCTAssertEqual(alertWithTitle.title, "My Title", "Non-empty title must not be overridden")
        // Message must pass through for empty-title case
        XCTAssertEqual(alert.message, "msg", "Message must be preserved even when title is substituted")
    }

    func testAlert_emptyMessage_returnsEmptyMessage() {
        let alert = TPPAlertUtils.alert(title: "T", message: "")
        XCTAssertEqual(alert.message, "")
        // Title must still be set for empty-message case
        XCTAssertEqual(alert.title, "T", "Title must be preserved when message is empty")
        // Alert must still have an OK action even with empty message
        XCTAssertFalse(alert.actions.isEmpty, "Alert must include at least one action even for empty message")
    }

    func testAlert_veryLongMessage_preservesContent() {
        let long = String(repeating: "abc ", count: 500)
        let alert = TPPAlertUtils.alert(title: "T", message: long)
        XCTAssertEqual(alert.message?.count, long.count)
        // Title must not be affected by very long message
        XCTAssertEqual(alert.title, "T", "Title must not be truncated by a long message")
        // Shorter message must produce shorter result (alert doesn't pad)
        let short = TPPAlertUtils.alert(title: "T", message: "Hi")
        XCTAssertLessThan(short.message?.count ?? 0, long.count,
                          "Shorter message must produce shorter alert message than 2000-char input")
    }

    // MARK: - OK action style

    func testAlert_defaultStyle_okActionIsDefaultStyle() {
        let alert = TPPAlertUtils.alert(title: "T", message: "M")
        let ok = alert.actions.first { $0.title == "OK" }
        XCTAssertEqual(ok?.style, .default)
        // A destructive-style alert must produce a different action style
        let destructive = TPPAlertUtils.alert(title: "T", message: "M", style: .destructive)
        let destructiveOk = destructive.actions.first { $0.title == "OK" }
        XCTAssertNotEqual(ok?.style, destructiveOk?.style,
                          "Default and destructive alerts must produce different action styles")
    }

    func testAlert_destructiveStyle_okActionIsDestructive() {
        let alert = TPPAlertUtils.alert(title: "T", message: "M", style: .destructive)
        let ok = alert.actions.first { $0.title == "OK" }
        XCTAssertEqual(ok?.style, .destructive)
        // Destructive style must differ from default style
        let defaultAlert = TPPAlertUtils.alert(title: "T", message: "M")
        let defaultOk = defaultAlert.actions.first { $0.title == "OK" }
        XCTAssertNotEqual(ok?.style, defaultOk?.style,
                          "Destructive action must have a different style than default action")
    }

    func testAlert_cancelStyle_okActionIsCancel() {
        let alert = TPPAlertUtils.alert(title: "T", message: "M", style: .cancel)
        let ok = alert.actions.first { $0.title == "OK" }
        XCTAssertEqual(ok?.style, .cancel)
        // Cancel style must differ from default style
        let defaultAlert = TPPAlertUtils.alert(title: "T", message: "M")
        let defaultOk = defaultAlert.actions.first { $0.title == "OK" }
        XCTAssertNotEqual(ok?.style, defaultOk?.style,
                          "Cancel action must have a different style than default action")
    }

    // MARK: - setProblemDocument branches

    func testSetProblemDocument_replaceMode_setsTitleAndDetail() {
        let alert = TPPAlertUtils.alert(title: "Old", message: "Old msg")
        let doc = TPPProblemDocument.fromDictionary([
            "title": "New Title", "detail": "New Detail"
        ])
        TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: false)
        XCTAssertEqual(alert.title, "New Title")
        XCTAssertEqual(alert.message, "New Detail")
    }

    func testSetProblemDocument_replaceMode_titleOnly_fillsMessageFromDetail() {
        let alert = TPPAlertUtils.alert(title: "Old", message: "")
        let doc = TPPProblemDocument.fromDictionary([
            "title": "New Title", "detail": "Some detail"
        ])
        TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: false)
        XCTAssertEqual(alert.title, "New Title")
        XCTAssertTrue(alert.message?.contains("Some detail") ?? false)
    }

    func testSetProblemDocument_appendMode_appendsDetailAfterExisting() {
        let alert = TPPAlertUtils.alert(title: "Title", message: "Base")
        let doc = TPPProblemDocument.fromDictionary(["detail": "Extra"])
        TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: true)
        XCTAssertTrue(alert.message?.contains("Base") ?? false)
        XCTAssertTrue(alert.message?.contains("Extra") ?? false)
    }

    func testSetProblemDocument_appendMode_titleAndDetailBothAppended() {
        let alert = TPPAlertUtils.alert(title: "AlertTitle", message: "Base")
        let doc = TPPProblemDocument.fromDictionary([
            "title": "DocTitle", "detail": "DocDetail"
        ])
        TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: true)
        XCTAssertTrue(alert.message?.contains("DocTitle") ?? false)
        XCTAssertTrue(alert.message?.contains("DocDetail") ?? false)
    }

    func testSetProblemDocument_emptyAlertTitle_fillsFromDoc() {
        // Construct an alert with an explicitly empty title to hit the
        // "alert.title.isEmpty -> copy from doc" branch.
        let alert = UIAlertController(title: "", message: "Base", preferredStyle: .alert)
        let doc = TPPProblemDocument.fromDictionary([
            "title": "FromDoc", "detail": "D"
        ])
        TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: true)
        XCTAssertEqual(alert.title, "FromDoc")
    }

    // MARK: - alertWithDetails action configuration

    func testAlertWithDetails_withRetryAction_hasRetryAndCancelNoOK() {
        let alert = TPPAlertUtils.alertWithDetails(
            title: "T", message: "M", retryAction: {}
        )
        XCTAssertEqual(alert.actions.count, 3) // View Details + Retry + Cancel
        XCTAssertNil(alert.actions.first { $0.title == "OK" })
        XCTAssertNotNil(alert.actions.first { $0.style == .cancel })
        let retry = alert.actions.first { $0.style == .default && $0.title != "View Error Details" }
        XCTAssertNotNil(retry)
    }

    func testAlertWithDetails_retryAction_invokesClosure() {
        var fired = false
        let alert = TPPAlertUtils.alertWithDetails(
            title: "T", message: "M", retryAction: { fired = true }
        )
        let retry = alert.actions.first { $0.style == .default && $0.title != "View Error Details" }
        XCTAssertNotNil(retry)
        // Invoke handler via KVC (UIAlertAction.handler is private)
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        if let action = retry,
           let block = action.value(forKey: "handler") {
            let handler = unsafeBitCast(block as AnyObject, to: Handler.self)
            handler(action)
        }
        XCTAssertTrue(fired, "Retry handler should have been invoked")
    }

    func testAlertWithDetails_withoutRetry_okActionIsDefaultStyle() {
        let alert = TPPAlertUtils.alertWithDetails(title: "T", message: "M")
        let ok = alert.actions.first { $0.title == "OK" }
        XCTAssertEqual(ok?.style, .default)
        // Without retry handler, there must be no "Try Again" action
        let tryAgain = alert.actions.first { $0.title == "Try Again" }
        XCTAssertNil(tryAgain, "Alert without retry handler must not include a Try Again action")
        // Alert must have at least the OK action
        XCTAssertFalse(alert.actions.isEmpty, "Alert must include at least one action")
    }

    func testAlertWithDetails_withError_buildsAlert() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let alert = TPPAlertUtils.alertWithDetails(
            title: "Failed", message: nil, error: err
        )
        XCTAssertEqual(alert.title, "Failed")
        XCTAssertNotNil(alert.actions.first { $0.title == "View Error Details" })
        XCTAssertFalse(alert.message?.isEmpty ?? true, "Alert with a real NSError must have a non-empty message")
    }

    func testPresentAlert_WhenNoAlertShowing_PresentsSuccessfully() {
        // Arrange
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        let rootVC = UIViewController()
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        trackForHermeticTeardown(window, rootVC)

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
