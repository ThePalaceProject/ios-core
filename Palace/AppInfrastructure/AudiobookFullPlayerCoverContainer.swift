//
//  AudiobookFullPlayerCoverContainer.swift
//  Palace
//
//  Module D (swarm_0b7616e7) — root-level `fullScreenCover` content
//  rendered by `AppTabHostView` when `presenter.isPlayerExpanded == true`.
//  Hosts the existing `AudiobookPlayerView` and wraps it in a custom
//  swipe-down gesture so the user can dismiss to the mini-player.
//
//  Swipe-down threshold: 100pt vertical translation with horizontal
//  drift under 60pt (filters out diagonal scrolls so legitimate vertical
//  swipes inside the player don't accidentally minimize). Reduce-motion
//  callers skip the implicit animation; everyone else gets `.easeInOut`.
//
//  When `presenter.playbackModel == nil` the container renders
//  `EmptyView()` so the cover never appears with an empty player —
//  belt-and-suspenders against a race where `isPlayerExpanded == true`
//  ran ahead of `adoptPlaybackModel(_:)` during a fast first-open.
//
//  Polish-phase additions (in-app-nav-polish-2026-06-01):
//
//    - Bug 1 fix: explicit top-leading chevron-down/Done button overlay
//      that calls `presenter.minimize()`. iOS users reported the player
//      had "no escape" because the existing 100pt swipe-down gesture
//      was not discoverable. The chevron sits in the safe area's top
//      inset, follows the `.regularMaterial` system convention for
//      navigation chrome, and is announced as "Dismiss player" to
//      VoiceOver.
//    - VoiceOver focus is moved into the player on expansion via
//      `UIAccessibility.post(.layoutChanged, argument: nil)` (announces
//      a layout change so the focus engine re-acquires from the
//      now-visible chrome — `@AccessibilityFocusState` bound through
//      the toolkit's `AudiobookPlayerView` isn't reachable since that
//      view is in a separate framework). The post is wrapped in a guard
//      against VoiceOver-off so non-VO users aren't impacted.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import PalaceAudiobookToolkit
import SwiftUI
import UIKit

@MainActor
struct AudiobookFullPlayerCoverContainer: View {

    @ObservedObject var presenter: AudiobookSessionPresenter

    /// Swipe-down threshold in points. Exposed for tests so the boundary
    /// case (just-under / just-over the threshold) can be asserted
    /// against the same constant the production gesture uses.
    static let minimizeSwipeDownThreshold: CGFloat = 100

    /// Maximum horizontal drift before a downward swipe stops counting
    /// as "vertical." Anything more than this is treated as a diagonal
    /// scroll and ignored. Filters out content-scroll gestures inside
    /// the player chrome.
    static let minimizeSwipeMaxHorizontalDrift: CGFloat = 60

    @ViewBuilder
    var body: some View {
        if let model = presenter.playbackModel {
            ZStack(alignment: .topLeading) {
                AudiobookPlayerView(model: model)
                    .gesture(swipeDownToMinimize)
                doneButtonOverlay
            }
            .onAppear {
                postVoiceOverLayoutChangeIfNeeded()
            }
            .onChange(of: presenter.isPlayerExpanded) { expanded in
                // Push focus into the cover on expand → true, and back
                // out (system handles) on expand → false. The same
                // `layoutChanged` post tells VoiceOver to re-acquire from
                // the now-visible chrome.
                if expanded { postVoiceOverLayoutChangeIfNeeded() }
            }
        } else {
            EmptyView()
        }
    }

    /// Top-leading chevron-down Done button overlay (Bug 1 fix —
    /// in-app-nav-polish-2026-06-01). iOS HIG convention for
    /// dismissing a sheet/cover is top-leading "Done" or top-trailing
    /// "X"; we picked top-leading chevron-down because the matching
    /// gesture is also vertical (swipe down), giving the user a
    /// consistent mental model: "going down = dismiss."
    private var doneButtonOverlay: some View {
        Button(action: minimizeWithMotionPreference) {
            Image(systemName: "chevron.down")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .padding(12)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .frame(width: 44, height: 44)
        .padding(.leading, 12)
        .padding(.top, 12)
        .accessibilityLabel(Strings.Generic.dismissPlayer)
        .accessibilityAddTraits(.isButton)
    }

    private var swipeDownToMinimize: some Gesture {
        DragGesture(minimumDistance: 50, coordinateSpace: .local)
            .onEnded { value in
                handleDragEnd(translation: value.translation)
            }
    }

    /// Test-visible drag-end handler. The test seam takes a raw
    /// `CGSize` so unit tests can simulate any drag without spinning
    /// up a real DragGesture. Production calls this from the
    /// `.onEnded` closure above.
    func handleDragEnd(translation: CGSize) {
        guard
            translation.height > Self.minimizeSwipeDownThreshold,
            abs(translation.width) < Self.minimizeSwipeMaxHorizontalDrift
        else {
            return
        }
        minimizeWithMotionPreference()
    }

    /// Drives `presenter.minimize()` honoring the user's reduce-motion
    /// preference. Wrapping in `withAnimation` adds an implicit
    /// easeInOut curve, which is exactly what reduce-motion users have
    /// asked the system NOT to do.
    private func minimizeWithMotionPreference() {
        if UIAccessibility.isReduceMotionEnabled {
            presenter.minimize()
        } else {
            withAnimation(.easeInOut) { presenter.minimize() }
        }
    }

    /// Posts a `.layoutChanged` UIAccessibility notification so the
    /// VoiceOver focus engine re-acquires from the newly-presented
    /// player chrome. Guarded on `UIAccessibility.isVoiceOverRunning`
    /// so non-VO users aren't impacted by an unnecessary post.
    ///
    /// `argument: nil` lets the system pick a sensible focus target
    /// (usually the first focusable element in the now-visible
    /// hierarchy). `@AccessibilityFocusState` would be the SwiftUI-
    /// native path, but the focusable target lives inside
    /// `AudiobookPlayerView` (toolkit) which we don't own — posting
    /// `layoutChanged` is the cross-framework-safe alternative.
    private func postVoiceOverLayoutChangeIfNeeded() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}
