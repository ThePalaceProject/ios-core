import XCTest
import UIKit
@testable import Palace

/// Pins where `TPPPresentationUtils.safelyPresent` presents from. Presenting
/// from a `UIAlertController` is the Crashlytics fe741015 crash shape
/// (PP-5348): the launch-time sign-in sheet after a refused token refresh
/// must wait for a visible alert to go away, then present, not be dropped.
@MainActor
final class TPPPresentationUtilsTests: XCTestCase {

    private var window: UIWindow?
    /// Retries queued behind a visible alert; tests run them by hand instead
    /// of waiting out the production poll interval.
    private var queuedRetries: [@MainActor () -> Void] = []

    override func tearDown() async throws {
        queuedRetries.removeAll()
        if let window {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            self.window = nil
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeRoot() -> UIViewController {
        let root = UIViewController()
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        return root
    }

    private func makeAlert(_ title: String = "Announcement") -> UIAlertController {
        let alert = UIAlertController(title: title, message: "Body", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }

    private func makeSheet() -> UIViewController {
        let sheet = UIViewController()
        sheet.modalPresentationStyle = .formSheet
        return sheet
    }

    private func safelyPresent(_ vc: UIViewController, root: UIViewController?,
                               completion: (() -> Void)? = nil) {
        TPPPresentationUtils.safelyPresent(vc, animated: false, completion: completion,
                                           rootProvider: { root },
                                           scheduleAlertRetry: { [unowned self] in queuedRetries.append($0) })
    }

    private func runQueuedRetry() {
        guard !queuedRetries.isEmpty else {
            XCTFail("no retry was queued")
            return
        }
        queuedRetries.removeFirst()()
    }

    private func present(_ vc: UIViewController, on presenter: UIViewController) {
        let shown = expectation(description: "\(type(of: vc)) shown")
        presenter.present(vc, animated: false) { shown.fulfill() }
        wait(for: [shown], timeout: 10)  // STARVE-001-OK: UIKit's own non-animated present completion on the main run loop; no background work
    }

    private func dismissPresented(on presenter: UIViewController) {
        let gone = expectation(description: "dismissed")
        presenter.dismiss(animated: false) { gone.fulfill() }
        wait(for: [gone], timeout: 10)  // STARVE-001-OK: UIKit's own non-animated dismiss completion on the main run loop; no background work
    }

    // MARK: - Visible alert

    /// The sign-in sheet raised by a refused token refresh must not be
    /// presented from an alert that is still on screen; it stays queued.
    func testSafelyPresent_WhenAlertIsVisible_DoesNotPresentFromTheAlert() {
        let root = makeRoot()
        let alert = makeAlert()
        present(alert, on: root)

        safelyPresent(makeSheet(), root: root)
        runQueuedRetry()

        XCTAssertNil(alert.presentedViewController,
                     "presenting from a UIAlertController is the fe741015 crash")
        XCTAssertTrue(root.presentedViewController === alert)
        XCTAssertEqual(queuedRetries.count, 1, "the presentation must stay queued while the alert is up")
    }

    /// Deferred, not dropped: once the alert is dismissed the queued sheet is
    /// presented from the controller that was showing the alert.
    func testSafelyPresent_WhenAlertIsVisible_PresentsAfterAlertIsDismissed() {
        let root = makeRoot()
        let alert = makeAlert()
        present(alert, on: root)
        let sheet = makeSheet()
        let completed = expectation(description: "caller's completion ran")

        safelyPresent(sheet, root: root, completion: { completed.fulfill() })
        dismissPresented(on: root)
        runQueuedRetry()

        XCTAssertTrue(root.presentedViewController === sheet)
        XCTAssertTrue(queuedRetries.isEmpty)
        // The caller's completion must survive the retry (AccountDetailViewModel passes one).
        wait(for: [completed], timeout: 10)  // STARVE-001-OK: UIKit's own non-animated present completion on the main run loop; no background work
    }

    /// An alert routed through `safelyPresent` (announcements, sign-in
    /// errors) waits behind a visible alert instead of stacking on it.
    func testSafelyPresent_AlertWhileAnotherAlertIsVisible_PresentsAfterFirstIsDismissed() {
        let root = makeRoot()
        let first = makeAlert("First")
        present(first, on: root)
        let second = makeAlert("Second")

        safelyPresent(second, root: root)
        XCTAssertNil(first.presentedViewController)
        dismissPresented(on: root)
        runQueuedRetry()

        XCTAssertTrue(root.presentedViewController === second)
    }

    /// An alert presented over a non-alert modal stops the walk at the
    /// alert, so the sheet waits for it rather than presenting from it.
    func testSafelyPresent_AlertOverModal_WaitsAndPresentsFromModal() {
        let root = makeRoot()
        let modal = UIViewController()
        present(modal, on: root)
        let alert = makeAlert()
        present(alert, on: modal)
        let sheet = makeSheet()

        safelyPresent(sheet, root: root)
        XCTAssertNil(alert.presentedViewController)
        dismissPresented(on: modal)
        runQueuedRetry()

        XCTAssertTrue(modal.presentedViewController === sheet)
    }

    // MARK: - No alert

    /// Without an alert the sheet is presented right away from the top-most
    /// presented controller, with nothing queued.
    func testSafelyPresent_WithModalAndNoAlert_PresentsFromTopmostModal() {
        let root = makeRoot()
        let modal = UIViewController()
        present(modal, on: root)
        let sheet = makeSheet()

        safelyPresent(sheet, root: root)

        XCTAssertTrue(modal.presentedViewController === sheet)
        XCTAssertTrue(queuedRetries.isEmpty)
    }

    /// A presentation still animating in is waited out through its
    /// transition coordinator; the alert is then presented, not dropped.
    func testSafelyPresent_DuringInFlightPresentation_PresentsAfterTransition() {
        let root = makeRoot()
        let modal = makeSheet()
        root.present(modal, animated: true)
        let alert = makeAlert()
        let presented = expectation(description: "alert presented")

        TPPPresentationUtils.safelyPresent(alert, animated: false,
                                           completion: { presented.fulfill() },
                                           rootProvider: { root },
                                           scheduleAlertRetry: { [unowned self] in queuedRetries.append($0) })

        wait(for: [presented], timeout: 10)  // STARVE-001-OK: waits on UIKit's own transition-coordinator completion for an animation started in this test; no background work
        XCTAssertTrue(modal.presentedViewController === alert)
    }

    /// No root controller: nothing is presented, nothing is queued, and the
    /// completion is not run.
    func testSafelyPresent_WithNoRoot_DoesNotRunCompletion() {
        var completionRan = false

        TPPPresentationUtils.safelyPresent(makeSheet(), animated: false,
                                           completion: { completionRan = true },
                                           rootProvider: { nil },
                                           scheduleAlertRetry: { [unowned self] in queuedRetries.append($0) })

        XCTAssertFalse(completionRan)
        XCTAssertTrue(queuedRetries.isEmpty)
    }
}
