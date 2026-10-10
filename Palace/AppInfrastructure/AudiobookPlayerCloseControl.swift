//
//  AudiobookPlayerCloseControl.swift
//  Palace
//

import SwiftUI

/// The full player's ✕: ends the session and removes both the full player and
/// the mini bar. Separate from `AudiobookMorphingPlayerView` because the player
/// draws it twice: in its top row, and above the opaque loading overlays that
/// cover that row (PP-5302).
struct AudiobookPlayerCloseButton: View {
    let presenter: AudiobookSessionPresenter

    var body: some View {
        // `.plain` hit-tests only the glyph; the content shape makes the whole
        // 44 pt layout frame touchable without moving anything (PP-5294).
        Button { presenter.closePlayer() } label: {
            Image(AudiobookMorphingPlayerView.icClose)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .accessibilityHidden(true)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).tint(.primary)
        .accessibilityLabel(Strings.Generic.close)
    }
}

/// The ✕ drawn above a loading overlay, at its own position in the player's top
/// row, so a patron can close a player that is still loading (PP-5302).
struct AudiobookPlayerCloseAboveLoadingOverlay: View {
    let presenter: AudiobookSessionPresenter
    let overlayState: AudiobookMorphingPlayerView.LoadingOverlayState
    let topInset: CGFloat

    var body: some View {
        if AudiobookMorphingPlayerView.loadingOverlayCoversControls(overlayState) {
            AudiobookPlayerCloseButton(presenter: presenter)
                .accessibilityIdentifier(AudiobookMorphingPlayerView.closeAboveLoadingOverlayIdentifier)
                .accessibilitySortPriority(1)
                .padding(.horizontal, 8)
                .padding(.top, topInset + 8)
        }
    }
}

extension AudiobookMorphingPlayerView {
    static let closeAboveLoadingOverlayIdentifier = "audiobookPlayer.closeAboveLoadingOverlay"

    /// The overlay states drawn opaque over the whole player, which hide the
    /// close control. `.awaitingReload` draws nothing and `.hidden` is loaded.
    nonisolated static func loadingOverlayCoversControls(_ state: LoadingOverlayState) -> Bool {
        switch state {
        case .skeleton, .downloading, .loadError: return true
        case .hidden, .awaitingReload: return false
        }
    }
}
