//
//  RatingFeedbackPresenter.swift
//  Palace
//
//  Feedback path for dissatisfied patrons (PP-4091). Routes a "Not really"
//  response to a pre-composed support email — never to the App Store.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

/// Abstraction over the feedback path so routing can be unit-tested with a spy.
@MainActor
protocol FeedbackPresenting {
  /// Presents the feedback mechanism (pre-composed support email). Never routes
  /// to the App Store.
  func presentFeedback()
}

/// Production `FeedbackPresenting` that opens a pre-filled mail composer to the
/// support address, reusing `ProblemReportEmail`. When no Mail account is
/// configured (`!canSendMail()`), `ProblemReportEmail` itself shows a fallback
/// alert with the address, so the patron is never left with a dead button.
@MainActor
final class RatingFeedbackPresenter: FeedbackPresenting {

  private let supportEmail: String
  private let composer: ProblemReportEmail
  private let topViewControllerProvider: @MainActor () -> UIViewController?

  init(
    supportEmail: String = SupportSectionDecision.generalFallbackEmail,
    composer: ProblemReportEmail = .sharedInstance,
    topViewControllerProvider: @escaping @MainActor () -> UIViewController? = {
      RatingFeedbackPresenter.topViewController()
    }
  ) {
    self.supportEmail = supportEmail
    self.composer = composer
    self.topViewControllerProvider = topViewControllerProvider
  }

  func presentFeedback() {
    guard let presenter = topViewControllerProvider() else { return }
    composer.beginComposing(
      to: supportEmail,
      presentingViewController: presenter,
      body: Self.feedbackBody
    )
  }

  /// A minimal, PII-free lead-in the patron can edit before sending.
  private static let feedbackBody = "\n\nWhat could we do better in The Palace Project?\n"

  /// Resolves the top-most presented view controller in the active foreground
  /// window scene, so the composer presents above whatever is on screen.
  static func topViewController() -> UIViewController? {
    let keyWindow = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })?
      .windows
      .first(where: { $0.isKeyWindow })

    var top = keyWindow?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
