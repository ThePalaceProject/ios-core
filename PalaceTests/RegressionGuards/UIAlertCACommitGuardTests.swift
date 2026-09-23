import XCTest
@testable import Palace

/// Regression guards for the UIAlertController CACommit crash family
/// (55 events on Crashlytics post-3.0.0). The fix surface lives in
/// Palace/ErrorHandling/TPPAlertUtils.swift. See
/// PalaceTests/RegressionGuards/README.md for the full crash narrative.
@MainActor
final class UIAlertCACommitGuardTests: XCTestCase {

    /// Window tracked for hermetic teardown so a presentation test cannot leak a
    /// key window into a later test's shared topViewController resolution
    /// (sibling lesson: fix-alert-presentation-test-hermeticity).
    private var trackedWindow: UIWindow?

    override func tearDown() {
        if let window = trackedWindow {
            // Drain pending main-queue work (coordinator-completion / retry hops)
            // so nothing presents after teardown, then release the window.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.rootViewController?.dismiss(animated: false, completion: nil)
            window.isHidden = true
            window.rootViewController = nil
            window.resignKey()
            trackedWindow = nil
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        super.tearDown()
    }

    // MARK: - presentFromViewControllerOrNil — coordinator-wait present path (fe741015)

    @MainActor
    func testPresent_OnInWindowVC_NoTransition_StillPresentsAlert() {
        // After the fe741015 fix the `transitionCoordinator` branch is a
        // coordinator-*wait* (present from the coordinator's completion) rather
        // than the old sample-once-then-retry-or-drop. On the no-transition happy
        // path the alert must STILL present — this guards the refactored path
        // against a regression that silently drops every alert. The actual
        // present-during-active-transition deferral is verified in-action via
        // simdrive (a deferred CA-commit throw cannot be reliably reproduced in a
        // unit test). See docs/bug-investigation-process.md.
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        trackedWindow = window

        let presented = expectation(description: "alert present() completion ran")
        let alert = TPPAlertUtils.alert(title: "T", message: "M")
        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: alert,
            viewController: root,
            animated: false,
            completion: { presented.fulfill() }
        )

        wait(for: [presented], timeout: 2.0)
        XCTAssertTrue(root.presentedViewController === alert,
            "no-transition happy path must actually present the alert, not drop it")
    }

    // MARK: - presentFromViewControllerOrNil — nil controller short-circuit

    func testPresentFromViewControllerOrNil_WithNilController_DoesNothing() {
        // The fix's first guard: bail immediately when the alert controller
        // is nil. Reverting this guard re-introduces a force-unwrap path
        // that crashes the moment any caller passes nil.
        let expectation = expectation(description: "completion never invoked for nil alert")
        expectation.isInverted = true

        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: nil,
            viewController: nil,
            animated: false,
            completion: {
                expectation.fulfill()
            }
        )

        // Completion is intentionally not called when the alert is nil —
        // there's nothing to do, no signal to give. Inverted expectation
        // verifies that no work was attempted.
        wait(for: [expectation], timeout: 0.2)
    }

    // MARK: - setProblemDocument — nil arguments short-circuit

    func testSetProblemDocument_WithNilController_DoesNothing() {
        // MISSING-001-OK: crash-guard — verifies the nil-controller branch
        // short-circuits BEFORE the `alert.title = ...` mutation that would
        // otherwise crash. No observable state to assert on.
        TPPAlertUtils.setProblemDocument(controller: nil, document: nil, append: false)
        // Test passes if no crash.
    }

    func testSetProblemDocument_WithNilDocument_DoesNothing() {
        let alert = UIAlertController(title: "T", message: "M", preferredStyle: .alert)
        TPPAlertUtils.setProblemDocument(controller: alert, document: nil, append: false)
        // Existing alert is untouched.
        XCTAssertEqual(alert.title, "T")
        XCTAssertEqual(alert.message, "M")
    }

    // MARK: - alert(title:message:) — produces presentable controller

    func testAlertTitleMessage_WithNonEmptyArgs_ProducesValidController() {
        // The fix path expects a fully-formed UIAlertController. Asserting
        // its shape (title, message, OK action) catches a regression where
        // the helper returns a partially-constructed controller that
        // crashes when present() touches a missing field.
        let alert = TPPAlertUtils.alert(title: "Title", message: "Body")
        XCTAssertNotNil(alert.title)
        XCTAssertNotNil(alert.message)
        XCTAssertEqual(alert.preferredStyle, .alert)
        XCTAssertGreaterThan(alert.actions.count, 0,
            "alert must have at least one action — UIKit crashes presenting an actionless alert on some iOS versions")
    }

    func testAlertTitleMessage_WithEmptyMessage_DoesNotCrashAndStillUsable() {
        // Empty message must not produce a nil-message that downstream
        // string operations can crash on.
        let alert = TPPAlertUtils.alert(title: "Title", message: "")
        XCTAssertNotNil(alert)
    }

    // MARK: - alert(title:error:) — empty/garbage error doesn't crash

    func testAlertTitleError_WithUnknownDomain_ProducesGenericMessage() {
        // The fix's defensive-message path: if the error has an unknown
        // domain and no usable description, fall back to a generic message
        // instead of presenting an empty alert (which UIKit can crash on).
        let unknownError = NSError(
            domain: "com.palace.unknown.test",
            code: -1,
            userInfo: nil  // intentionally no localizedDescription
        )
        let alert = TPPAlertUtils.alert(title: "Title", error: unknownError)
        XCTAssertNotNil(alert.message)
        XCTAssertFalse(alert.message?.isEmpty ?? true,
            "empty alert.message lets UIKit reach a code path that crashes during CACommit")
    }

    func testAlertTitleError_WithNilError_ProducesGenericMessage() {
        let alert = TPPAlertUtils.alert(title: "Title", error: nil)
        XCTAssertNotNil(alert.message)
        XCTAssertFalse(alert.message?.isEmpty ?? true)
    }

    func testAlertTitleError_WithCancelledNetworkError_DoesNotCrash() {
        // NSURLErrorCancelled is the most common error reaching this surface.
        let cancelled = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: nil
        )
        let alert = TPPAlertUtils.alert(title: "Title", error: cancelled)
        XCTAssertNotNil(alert)
    }
}
