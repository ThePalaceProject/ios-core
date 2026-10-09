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

    override func tearDown() {
        if let window {
            window.rootViewController?.dismiss(animated: false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.isHidden = true
            window.rootViewController = nil
            self.window = nil
        }
        super.tearDown()
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

    private func present(_ vc: UIViewController, on presenter: UIViewController) {
        let shown = expectation(description: "\(type(of: vc)) shown")
        presenter.present(vc, animated: false) { shown.fulfill() }
        wait(for: [shown], timeout: 2)
    }

    private func dismissPresented(on presenter: UIViewController) {
        let gone = expectation(description: "dismissed")
        presenter.dismiss(animated: false) { gone.fulfill() }
        wait(for: [gone], timeout: 2)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Visible alert

    /// The sign-in sheet raised by a refused token refresh must not be
    /// presented from an alert that is already on screen.
    func testSafelyPresent_WhenAlertIsVisible_DoesNotPresentFromTheAlert() {
        let root = makeRoot()
        let alert = makeAlert()
        present(alert, on: root)
        let sheet = makeSheet()

        TPPPresentationUtils.safelyPresent(sheet, animated: false, completion: nil,
                                           rootProvider: { root })
        pump(0.6)

        XCTAssertNil(alert.presentedViewController,
                     "presenting from a UIAlertController is the fe741015 crash")
        XCTAssertTrue(root.presentedViewController === alert)
    }

    /// Deferred, not dropped: once the alert is dismissed the sheet is
    /// presented from the controller that was showing the alert.
    func testSafelyPresent_WhenAlertIsVisible_PresentsAfterAlertIsDismissed() {
        let root = makeRoot()
        let alert = makeAlert()
        present(alert, on: root)
        let sheet = makeSheet()
        let presented = expectation(description: "sheet presented")

        TPPPresentationUtils.safelyPresent(sheet, animated: false,
                                           completion: { presented.fulfill() },
                                           rootProvider: { root })
        pump(0.3)
        dismissPresented(on: root)

        wait(for: [presented], timeout: 3)
        XCTAssertTrue(root.presentedViewController === sheet)
    }

    /// An alert routed through `safelyPresent` (announcements, sign-in
    /// errors) waits behind a visible alert instead of stacking on it.
    func testSafelyPresent_AlertWhileAnotherAlertIsVisible_PresentsAfterFirstIsDismissed() {
        let root = makeRoot()
        let first = makeAlert("First")
        present(first, on: root)
        let second = makeAlert("Second")
        let presented = expectation(description: "second alert presented")

        TPPPresentationUtils.safelyPresent(second, animated: false,
                                           completion: { presented.fulfill() },
                                           rootProvider: { root })
        pump(0.3)
        XCTAssertNil(first.presentedViewController)
        dismissPresented(on: root)

        wait(for: [presented], timeout: 3)
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
        let presented = expectation(description: "sheet presented")

        TPPPresentationUtils.safelyPresent(sheet, animated: false,
                                           completion: { presented.fulfill() },
                                           rootProvider: { root })
        pump(0.3)
        XCTAssertNil(alert.presentedViewController)
        dismissPresented(on: modal)

        wait(for: [presented], timeout: 3)
        XCTAssertTrue(modal.presentedViewController === sheet)
    }

    // MARK: - No alert

    /// Without an alert the sheet is presented right away from the top-most
    /// presented controller.
    func testSafelyPresent_WithModalAndNoAlert_PresentsFromTopmostModal() {
        let root = makeRoot()
        let modal = UIViewController()
        present(modal, on: root)
        let sheet = makeSheet()
        let presented = expectation(description: "sheet presented")

        TPPPresentationUtils.safelyPresent(sheet, animated: false,
                                           completion: { presented.fulfill() },
                                           rootProvider: { root })

        wait(for: [presented], timeout: 2)
        XCTAssertTrue(modal.presentedViewController === sheet)
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
                                           rootProvider: { root })

        wait(for: [presented], timeout: 3)
        XCTAssertTrue(modal.presentedViewController === alert)
    }

    /// No root controller: nothing is presented and the completion is not run.
    func testSafelyPresent_WithNoRoot_DoesNotRunCompletion() {
        let notCalled = expectation(description: "completion not called")
        notCalled.isInverted = true

        TPPPresentationUtils.safelyPresent(makeSheet(), animated: false,
                                           completion: { notCalled.fulfill() },
                                           rootProvider: { nil })

        wait(for: [notCalled], timeout: 0.3)
    }
}
