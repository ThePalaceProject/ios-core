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
//  Tap → `presenter.expand()` (full-player root fullScreenCover opens).
//  Play/pause button → caller-supplied `togglePlayPauseAction` closure
//  (AppTabHostView wires this to `appContainer.audiobookSession
//  .togglePlayPause()`).
//
//  `isPlayingProvider` and `coverImageProvider` are also closure-injected
//  because the toolkit's `AudiobookPlaybackModel` keeps `isPlaying` and
//  `coverImage` at internal access — Palace cannot read them directly
//  through the `presenter.playbackModel` reference. Production wires
//  both providers to the session manager (`isPlaying`, `coverImage` are
//  public on `AudiobookSessionManaging`). Tests pass closures returning
//  fixed values so chrome state can be asserted deterministically.
//
//  Hit targets stay >= 44pt at Dynamic Type AX5 by truncating title
//  before hiding controls.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import PalaceAudiobookToolkit
import SwiftUI
import UIKit

@MainActor
struct AudiobookMiniPlayerView: View {

    @ObservedObject var presenter: AudiobookSessionPresenter

    /// Returns the current `isPlaying` state. Production wires this to
    /// `appContainer.audiobookSession.isPlaying`; tests pass a closure
    /// returning a fixed bool.
    let isPlayingProvider: () -> Bool

    /// Returns the current cover image. Production wires this to
    /// `appContainer.audiobookSession.coverImage`; tests pass a closure
    /// returning a fixed image (or nil for the placeholder branch).
    let coverImageProvider: () -> UIImage?

    /// Toggles play/pause on the underlying session. Production wires
    /// this to `appContainer.audiobookSession.togglePlayPause()`; tests
    /// pass a closure that records the call so the play/pause-button
    /// wiring can be asserted without spinning up the session graph.
    let togglePlayPauseAction: () -> Void

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
        HStack(spacing: 12) {
            coverImage
            titleStack
            Spacer(minLength: 8)
            playPauseButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .contentShape(Rectangle())
        .onTapGesture { presenter.expand() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Strings.Generic.expandPlayerHint)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var coverImage: some View {
        coverImageOrPlaceholder
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var coverImageOrPlaceholder: some View {
        if let cover = coverImageProvider() {
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

    private var titleStack: some View {
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
        }
        .accessibilityHidden(true)
    }

    private var playPauseButton: some View {
        // 44pt min hit target preserved at AX5 — the button uses
        // `frame(width:44, height:44)` so Dynamic Type can grow the icon
        // glyph but never shrinks the touchable area.
        Button(action: togglePlayPauseAction) {
            Image(systemName: isPlayingProvider() ? "pause.fill" : "play.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(12)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlayingProvider() ? Strings.Generic.pauseAudiobook : Strings.Generic.playAudiobook)
    }

    // MARK: - Derived

    private var accessibilityLabel: String {
        let title = presenter.currentBook?.title ?? ""
        let author = presenter.currentBook?.authors ?? ""
        if author.isEmpty {
            return String(format: Strings.Generic.nowPlayingLabelTitleOnly, title)
        }
        return String(format: Strings.Generic.nowPlayingLabelTitleAndAuthor, title, author)
    }
}
