//
//  AudiobookMiniPlayerView.swift
//  Palace
//
//  Module D (swarm_0b7616e7) — root-level mini-player chrome rendered
//  via `safeAreaInset(edge: .bottom)` on `AppTabHostView`'s `TabView`.
//
//  Visibility predicate (§7.3 Option α): `presenter.hasActiveSession &&
//  !presenter.isReaderActive`. The mini-player shows when an audiobook
//  session is active AND the user is not in a reader. When suppressed,
//  the view renders `EmptyView()` so SwiftUI removes it from the
//  hierarchy entirely (no opacity tricks, no zero-frame chrome — pure
//  structural absence per the design doc's "no leak" requirement).
//
//  Polish-phase rewrite (in-app-nav-polish-2026-06-01):
//
//    - Chrome upgraded from cover+title+play/pause to sample-style layout:
//      cover (44x44) | title+author+time+scrubber | skipBack/playPause/
//      skipForward. All controls maintain 44pt min hit targets at AX5.
//    - `.ultraThinMaterial` background for the SwiftUI-modern look.
//    - All state reads off `presenter.@Published` props (no more closure
//      providers): `presenter.isPlaying`, `presenter.coverImage`,
//      `presenter.playbackProgress`, `presenter.currentLocation`,
//      `presenter.currentBook`.
//    - Actions route through the injected `audiobookSession` parameter
//      (`AudiobookSessionManaging`): `togglePlayPause()`, `skipBack()`,
//      `skipForward()`. The skip methods are new on the protocol
//      (in-app-nav-polish-2026-06-01) and wrap toolkit `Player
//      .skipPlayhead(_:)` via a Task boundary in the concrete manager.
//    - Tap → `presenter.expand()` opens the full-player fullScreenCover.
//
//  Hit targets stay >= 44pt at Dynamic Type AX5 by truncating title +
//  author before hiding controls. Controls themselves are pinned at
//  `frame(width: 44, height: 44)`.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import PalaceAudiobookToolkit
import SwiftUI
import UIKit

@MainActor
struct AudiobookMiniPlayerView: View {

    @ObservedObject var presenter: AudiobookSessionPresenter

    /// Session manager used for transport actions (play/pause + 30s skips).
    /// Injected so tests can substitute a `SpyShimSession` or any
    /// `AudiobookSessionManaging` fake without touching the AppContainer
    /// cache. Production wires this to `appContainer.audiobookSession`.
    let audiobookSession: AudiobookSessionManaging

    @ViewBuilder
    var body: some View {
        if Self.shouldShowChrome(hasActiveSession: presenter.hasActiveSession, isReaderActive: presenter.isReaderActive) {
            miniPlayerChrome
        } else {
            EmptyView()
        }
    }

    /// Pure decision predicate extracted for unit testability —
    /// without extraction, the mutation `&&` → `||` survives because
    /// SwiftUI bodies are opaque and the test can only read the
    /// flags it set. The static fn makes the truth table directly
    /// testable. §7.3 Option α — mini-player visible iff session active
    /// AND not in a reader.
    static func shouldShowChrome(hasActiveSession: Bool, isReaderActive: Bool) -> Bool {
        return hasActiveSession && !isReaderActive
    }

    // MARK: - Chrome

    private var miniPlayerChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                coverImage
                    .accessibilityHidden(true)
                    .contentShape(Rectangle())
                    .onTapGesture { expandWithMotionPreference() }
                titleAndTimeStack
                    .accessibilityHidden(true)
                    .contentShape(Rectangle())
                    .onTapGesture { expandWithMotionPreference() }
                Spacer(minLength: 4)
                skipBackButton
                playPauseButton
                skipForwardButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            scrubber
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Strings.Generic.expandPlayerHint)
    }

    /// Drives `presenter.expand()` and honors the user's reduce-motion
    /// preference — wrapping in `withAnimation` adds an implicit easeInOut
    /// curve, which is exactly what reduce-motion users have asked the
    /// system NOT to do. Posts a `.layoutChanged` UIAccessibility
    /// notification so VoiceOver re-acquires focus from the now-presented
    /// full player chrome (paired with the full player's own onAppear
    /// post — either side firing first ensures focus moves on time).
    private func expandWithMotionPreference() {
        if UIAccessibility.isReduceMotionEnabled {
            presenter.expand()
        } else {
            withAnimation(.easeInOut) { presenter.expand() }
        }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        coverImageOrPlaceholder
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var coverImageOrPlaceholder: some View {
        if let cover = presenter.coverImage {
            Image(uiImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "book.closed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.secondary)
                .padding(8)
        }
    }

    private var titleAndTimeStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(presenter.currentBook?.title ?? "")
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
            if let authors = presenter.currentBook?.authors, !authors.isEmpty {
                Text(authors)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(timeLabel)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var skipBackButton: some View {
        Button(action: { audiobookSession.skipBack() }) {
            Image(systemName: "gobackward.30")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(10)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .tint(.accentColor)
        .accessibilityLabel(Strings.Generic.skipBack30)
    }

    private var playPauseButton: some View {
        // 44pt min hit target preserved at AX5 — the button uses
        // `frame(width:44, height:44)` so Dynamic Type can grow the icon
        // glyph but never shrinks the touchable area.
        Button(action: { audiobookSession.togglePlayPause() }) {
            Image(systemName: presenter.isPlaying ? "pause.fill" : "play.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(12)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .tint(.accentColor)
        .accessibilityLabel(presenter.isPlaying ? Strings.Generic.pauseAudiobook : Strings.Generic.playAudiobook)
    }

    private var skipForwardButton: some View {
        Button(action: { audiobookSession.skipForward() }) {
            Image(systemName: "goforward.30")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(10)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .tint(.accentColor)
        .accessibilityLabel(Strings.Generic.skipForward30)
    }

    private var scrubber: some View {
        ProgressView(value: presenter.playbackProgress.isFinite ? min(max(presenter.playbackProgress, 0), 1) : 0,
                     total: 1.0)
            .progressViewStyle(.linear)
            .tint(.accentColor)
            .frame(maxWidth: .infinity)
            .frame(height: 2)
            .accessibilityHidden(true)
    }

    // MARK: - Derived

    /// "MM:SS / MM:SS" — elapsed-on-book / total-book. Falls back to
    /// `"--:-- / --:--"` when no position has loaded yet. We use the
    /// whole-book duration (not chapter) because the scrubber is also
    /// whole-book — keeping the label and scrubber semantically aligned.
    private var timeLabel: String {
        guard let position = presenter.currentLocation else {
            return "--:-- / --:--"
        }
        let elapsed = position.durationToSelf()
        let total = position.tracks.totalDuration
        return "\(Self.formatTime(elapsed)) / \(Self.formatTime(total))"
    }

    /// Pure `TimeInterval` → "MM:SS" / "H:MM:SS" formatter. Negative or
    /// non-finite inputs render "--:--". `static` so the polish-phase
    /// tests can pin the format without spinning up the view body.
    static func formatTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "--:--" }
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var accessibilityLabel: String {
        let title = presenter.currentBook?.title ?? ""
        let author = presenter.currentBook?.authors ?? ""
        if author.isEmpty {
            return String(format: Strings.Generic.nowPlayingLabelTitleOnly, title)
        }
        return String(format: Strings.Generic.nowPlayingLabelTitleAndAuthor, title, author)
    }
}
