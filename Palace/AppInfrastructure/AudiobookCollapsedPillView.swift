//
//  AudiobookCollapsedPillView.swift
//  Palace
//
//  The compact "collapsed" form of the root-level audiobook player. When the
//  user swipes the mini-bar down (`AudiobookMiniPlayerView` →
//  `presenter.collapse()`), the full-width bar is replaced by this small
//  floating capsule pinned bottom-trailing above the tab bar. Playback keeps
//  running — collapsing is strictly a chrome change.
//
//  Interaction:
//    - Tap the cover thumbnail → `presenter.restoreFromCollapsed()` brings the
//      full mini-bar back. (Same "tap the artwork to open the player" idiom
//      the mini-bar uses for expand.)
//    - Tap the play/pause glyph → `audiobookSession.togglePlayPause()`, so the
//      user retains transport control without restoring the whole bar.
//
//  This is the third state on the now-playing surface's two axes:
//    full player  ⇄  mini-bar  ⇄  collapsed pill        (+ hard dismiss `✕`)
//                    isPlayerExpanded   isCollapsed
//
//  Visibility predicate is the exact complement of
//  `AudiobookMiniPlayerView.shouldShowChrome` on the collapsed axis:
//  `hasActiveSession && !isReaderActive && isCollapsed`. Extracted `static`
//  for the same mutation-testability reason (SwiftUI bodies are opaque).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import PalaceAudiobookToolkit
import SwiftUI
import UIKit

@MainActor
struct AudiobookCollapsedPillView: View {

    @ObservedObject var presenter: AudiobookSessionPresenter

    /// Session manager used for the pill's play/pause control. Injected so
    /// tests can substitute a `SpyShimSession` — same seam the mini-bar uses.
    let audiobookSession: AudiobookSessionManaging

    /// Pure visibility predicate — the complement of
    /// `AudiobookMiniPlayerView.shouldShowChrome` on the `isCollapsed` axis.
    /// The pill shows iff there's an active session, we're not in a reader,
    /// AND the user has collapsed the bar. Extracted `static` so the
    /// `&&` / `!` operators are mutation-testable directly.
    static func shouldShow(hasActiveSession: Bool, isReaderActive: Bool, isCollapsed: Bool) -> Bool {
        return hasActiveSession && !isReaderActive && isCollapsed
    }

    var body: some View {
        HStack(spacing: 6) {
            coverThumbnail
                .contentShape(Rectangle())
                .onTapGesture { restore() }
            playPauseButton
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Strings.Generic.restoreAudiobookPlayerHint)
    }

    // MARK: - Subviews

    // Split the if/else into its own `@ViewBuilder` var WITHOUT a `Group`
    // wrapper, then apply frame/clip in this wrapper — same shape the
    // mini-player uses to dodge Xcode 26's `Group`-modifier CodingKey
    // mis-inference (see `AudiobookMiniPlayerView.coverImageOrPlaceholder`).
    @ViewBuilder
    private var coverThumbnail: some View {
        coverThumbnailImage
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var coverThumbnailImage: some View {
        if let cover = presenter.coverImage {
            Image(uiImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "book.closed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .padding(7)
        }
    }

    private var playPauseButton: some View {
        Button(action: { audiobookSession.togglePlayPause() }) {
            Image(systemName: presenter.isPlaying ? "pause.fill" : "play.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(12)
                .frame(width: 40, height: 40)
                .contentTransition(.symbolEffect(.replace))
                .accessibleAnimation(PalaceMotion.standard, value: presenter.isPlaying)
        }
        .buttonStyle(.plain)
        .tint(.accentColor)
        .accessibilityLabel(presenter.isPlaying ? Strings.Generic.pauseAudiobook : Strings.Generic.playAudiobook)
    }

    // MARK: - Actions

    /// Restores the full mini-bar from the pill, honoring reduce-motion.
    private func restore() {
        if UIAccessibility.isReduceMotionEnabled {
            presenter.restoreFromCollapsed()
        } else {
            withAnimation(PalaceMotion.standard) { presenter.restoreFromCollapsed() }
        }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    // MARK: - Derived

    private var accessibilityLabel: String {
        let title = presenter.currentBook?.title ?? ""
        return String(format: Strings.Generic.nowPlayingCompactLabel, title)
    }
}
