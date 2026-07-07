//
//  SentimentGateView.swift
//  Palace
//
//  The app-rating sentiment gate (PP-4089): a lightweight, dismissible card
//  shown after a positive moment. Yes → native review (PP-4090); Not really →
//  feedback follow-up (PP-4091); Ask me later / tap-outside → defer.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// A root-level overlay that renders the rating flow when the presenter has an
/// active `step`, and nothing otherwise. Designed to be placed as a sibling
/// layer in `AppTabHostView`'s root `ZStack` so it survives tab switches.
struct SentimentGateView: View {
  @ObservedObject var presenter: RatingPromptPresenter
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private typealias L = Strings.AppRating

  var body: some View {
    ZStack {
      // Dimmed, tap-to-dismiss backdrop. Gated on `step != nil` (NOT on the
      // step VALUE) so it stays mounted continuously across the
      // sentiment→feedback card swap. If it lived inside `if let step` it would
      // be torn down/rebuilt on each value change, and during the card's scale
      // transition a rapid tap leaked THROUGH to the content behind the gate
      // (chaos-QA, PP-4716). `contentShape` makes the whole frame absorb taps.
      if presenter.step != nil {
        Color.black.opacity(0.4)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { presenter.dismiss() }
          .accessibilityLabel(Text(L.askLater))
          .accessibilityAction { presenter.dismiss() }
      }

      if let step = presenter.step {
        card(for: step)
          .transition(Self.cardTransition(reduceMotion: reduceMotion))
      }
    }
    .animation(Self.stepAnimation(reduceMotion: reduceMotion), value: presenter.step)
  }

  // MARK: - Reduce-Motion-gated presentation (pure, testable)

  /// The card's enter/exit transition. Under Reduce Motion it collapses to a
  /// plain opacity fade with no scaling (the prior code always scaled, ignoring
  /// the setting); otherwise it keeps the subtle opacity + 0.96 scale pop.
  static func cardTransition(reduceMotion: Bool) -> AnyTransition {
    usesScaleTransition(reduceMotion: reduceMotion)
      ? .opacity.combined(with: .scale(scale: 0.96))
      : .opacity
  }

  /// Whether the card transition includes a scale component. `false` under
  /// Reduce Motion. Exposed so the gate can be unit-tested without a host.
  static func usesScaleTransition(reduceMotion: Bool) -> Bool {
    !reduceMotion
  }

  /// Animation for the sentiment -> feedback card swap. Emphasized spring
  /// normally; `nil` (no animation) under Reduce Motion.
  static func stepAnimation(reduceMotion: Bool) -> Animation? {
    PalaceMotion.resolved(PalaceMotion.emphasized, reduceMotion: reduceMotion)
  }

  @ViewBuilder
  private func card(for step: RatingPromptStep) -> some View {
    VStack(spacing: 20) {
      switch step {
      case .sentiment:
        Text(L.sentimentTitle)
          .font(.headline)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        VStack(spacing: 12) {
          primaryButton(L.positive) { presenter.respondPositive() }
          secondaryButton(L.negative) { presenter.respondNegative() }
          tertiaryButton(L.askLater) { presenter.respondAskLater() }
        }

      case .feedbackFollowup:
        Text(L.feedbackTitle)
          .font(.headline)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        VStack(spacing: 12) {
          primaryButton(L.feedbackConfirm) { presenter.confirmFeedback() }
          tertiaryButton(L.feedbackDecline) { presenter.declineFeedback() }
        }
      }
    }
    .padding(24)
    .frame(maxWidth: 340)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color(.secondarySystemBackground))
    )
    .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    .padding(32)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
  }

  // MARK: - Button styles
  //
  // Colors are chosen to guarantee contrast in BOTH light and dark mode. We do
  // NOT use `Color.accentColor` here: in this app it resolves to ~white in dark
  // mode, which made the filled primary button render white-on-white (invisible
  // label). The primary uses the fixed brand navy (`palaceBlueBase`, identical
  // in both appearances) with white text; the secondary/tertiary use the
  // semantic label colors (`.primary`/`.secondary`) which always contrast with
  // the card's `secondarySystemBackground`.

  private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .fontWeight(.semibold)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.palaceBlueBase)
        .foregroundColor(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.primary, lineWidth: 1)
        )
        .foregroundColor(.primary)
    }
  }

  private func tertiaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .foregroundColor(.secondary)
    }
  }
}
