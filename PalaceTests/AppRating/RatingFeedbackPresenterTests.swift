//
//  RatingFeedbackPresenterTests.swift
//  PalaceTests
//
//  Tests for the feedback path (PP-4091): it composes to the support address
//  from the resolved top view controller, and no-ops safely when there is no
//  presenter — never routing to the App Store.
//

import XCTest
import UIKit
@testable import Palace

@MainActor
final class RatingFeedbackPresenterTests: XCTestCase {

  /// Spy over ProblemReportEmail's composing call. ProblemReportEmail is a
  /// concrete singleton, so we subclass to intercept the reused entry point.
  private final class SpyComposer: ProblemReportEmail {
    private(set) var toAddress: String?
    private(set) var presentingVC: UIViewController?
    private(set) var callCount = 0
    override func beginComposing(to emailAddress: String, presentingViewController: UIViewController, body: String) {
      callCount += 1
      toAddress = emailAddress
      presentingVC = presentingViewController
    }
  }

  func testPresentFeedback_composesToSupportFromTopViewController() {
    let spy = SpyComposer()
    let host = UIViewController()
    let presenter = RatingFeedbackPresenter(
      supportEmail: "support@example.org",
      composer: spy,
      topViewControllerProvider: { host }
    )

    presenter.presentFeedback()

    XCTAssertEqual(spy.callCount, 1)
    XCTAssertEqual(spy.toAddress, "support@example.org")
    XCTAssertTrue(spy.presentingVC === host)
  }

  func testPresentFeedback_withNoTopViewController_isSafeNoOp() {
    let spy = SpyComposer()
    let presenter = RatingFeedbackPresenter(
      supportEmail: "support@example.org",
      composer: spy,
      topViewControllerProvider: { nil }
    )

    presenter.presentFeedback()

    XCTAssertEqual(spy.callCount, 0, "no presenter → must not attempt to compose")
  }

  func testDefaultInit_wiresComposerToPalaceSupportAddress() {
    // Exercises the PRODUCTION default supportEmail wiring (not just the
    // constant): a default-constructed presenter must compose to the palace
    // support address. Injects only the composer + a stub top-VC so the real
    // default `supportEmail` is used.
    let spy = SpyComposer()
    let host = UIViewController()
    let presenter = RatingFeedbackPresenter(
      composer: spy,
      topViewControllerProvider: { host }
    )

    presenter.presentFeedback()

    XCTAssertEqual(spy.toAddress, "support@thepalaceproject.org",
                   "default presenter must route feedback to the configured palace support address")
  }
}
