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

  private typealias L = Strings.AppRating

  var body: some View {
    ZStack {
      if let step = presenter.step {
        // Dimmed, tap-to-dismiss backdrop.
        Color.black.opacity(0.4)
          .ignoresSafeArea()
          .onTapGesture { presenter.dismiss() }
          .accessibilityLabel(Text(L.askLater))
          .accessibilityAction { presenter.dismiss() }

        card(for: step)
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
      }
    }
    .animation(.easeInOut(duration: 0.25), value: presenter.step)
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
