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
            AudiobookPlayerView(model: model)
                .gesture(swipeDownToMinimize)
        } else {
            EmptyView()
        }
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
        if UIAccessibility.isReduceMotionEnabled {
            presenter.minimize()
        } else {
            withAnimation(.easeInOut) { presenter.minimize() }
        }
    }
}
