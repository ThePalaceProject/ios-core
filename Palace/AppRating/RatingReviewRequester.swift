//
//  RatingReviewRequester.swift
//  Palace
//
//  Native App Store review request (PP-4090). Thin wrapper over StoreKit's
//  system prompt — no custom UI, no incentive (App Store Guideline §5.6.1).
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import StoreKit
import UIKit

/// Abstraction over the system review prompt so routing can be unit-tested
/// with a spy (the real `SKStoreReviewController` call is untestable — the
/// prompt only appears in TestFlight/production and is iOS-rate-limited).
@MainActor
protocol ReviewRequesting {
  /// Requests the native App Store rating prompt. Display is not guaranteed;
  /// iOS may decline, in which case the patron experience continues normally.
  func requestReview()
}

/// Production `ReviewRequesting` that invokes the system prompt in the active
/// foreground window scene.
@MainActor
final class RatingReviewRequester: ReviewRequesting {
  // no-superpartner: SKStoreReviewController.requestReview only surfaces in
  // TestFlight/production and is iOS-rate-limited — unobservable in a unit test.
  // The routing that reaches this call is covered via the ReviewRequesting spy
  // (RatingPromptPresenterTests); the real prompt is exercised by simdrive/manual
  // QA (PP-4716 / PP-4092).
  func requestReview() {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
    else {
      return
    }
    SKStoreReviewController.requestReview(in: scene)
  }
}
