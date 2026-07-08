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
//    - State reads off `presenter` (`isPlaying`, `coverImage`, `currentBook`)
//      and the separate high-frequency `progress` object
//      (`progress.playbackProgress`, `progress.currentLocation`) so per-tick
//      scrubber updates re-render only this leaf, not the presenter's root
//      observer (`AppTabHostView`).
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

    /// High-frequency scrubber state, observed here rather than via the
    /// presenter so per-tick progress re-renders only this leaf (not the root).
    @ObservedObject var progress: AudiobookPlaybackProgress

    /// Session manager used for transport actions (play/pause + 30s skips).
    /// Injected so tests can substitute a `SpyShimSession` or any
    /// `AudiobookSessionManaging` fake without touching the AppContainer
    /// cache. Production wires this to `appContainer.audiobookSession`.
    let audiobookSession: AudiobookSessionManaging

    /// Guards against a rapid double-tap on `✕` enqueuing two teardowns: the
    /// button stays mounted until `hasActiveSession` flips false (after the
    /// async `stopPlayback` completes), so without this a second tap in that
    /// window would fire a second `stopPlayback`. `stopPlayback` is idempotent,
    /// but one teardown is the correct contract.
    @State private var isDismissing = false

    @ViewBuilder
    var body: some View {
        // SwiftUI.Group + explicit else: Xcode 26's type-checker otherwise
        // mis-picks a Group initializer (CodingKey cascade) for an if-without-
        // else inside a modified Group.
        SwiftUI.Group {
            if Self.shouldShowChrome(hasActiveSession: presenter.hasActiveSession,
                                     isReaderActive: presenter.isReaderActive,
                                     isCollapsed: presenter.isCollapsed) {
                miniPlayerChrome
                    // Slide in/out from the bottom (paired with a fade) instead
                    // of popping when a session starts/ends or a reader opens.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                EmptyView()
            }
        }
        .accessibleAnimation(PalaceMotion.standard,
                             value: Self.shouldShowChrome(hasActiveSession: presenter.hasActiveSession,
                                                          isReaderActive: presenter.isReaderActive,
                                                          isCollapsed: presenter.isCollapsed))
    }

    /// Pure decision predicate extracted for unit testability —
    /// without extraction, the mutation `&&` → `||` survives because
    /// SwiftUI bodies are opaque and the test can only read the
    /// flags it set. The static fn makes the truth table directly
    /// testable. §7.3 Option α — mini-player visible iff session active
    /// AND not in a reader AND not collapsed to the pill (`isCollapsed`
    /// hands off to `AudiobookCollapsedPillView` — see that view's
    /// `shouldShow` predicate, which is the exact complement on the
    /// collapsed axis).
    static func shouldShowChrome(hasActiveSession: Bool, isReaderActive: Bool, isCollapsed: Bool) -> Bool {
        return hasActiveSession && !isReaderActive && !isCollapsed
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
                dismissButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            scrubber
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        // Swipe the bar DOWN to collapse it to the compact floating pill
        // (playback keeps running). Paired with the visible `✕` button that
        // performs the hard dismiss — same discoverability lesson the full
        // player learned (a gesture alone wasn't discoverable, so we ship
        // both a gesture AND a visible control).
        .gesture(swipeDownToCollapse)
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
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(timeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                // Play<->pause glyph cross-fades via the SF Symbol replace effect
                // instead of hard-swapping the image.
                .contentTransition(.symbolEffect(.replace))
                .accessibleAnimation(PalaceMotion.standard, value: presenter.isPlaying)
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

    /// The `✕` hard-dismiss control. Unlike the swipe-down collapse (which
    /// only tucks the bar into the pill and keeps audio playing), this ENDS
    /// the session: `stopPlayback(dismissPhoneUI: true, persistFinalPosition:
    /// true)` saves the final position, tears down the toolkit player, and —
    /// via `dismissPlayerOnPhone` → `clearActiveSession()` — drops both the
    /// mini-bar and the pill. Re-opening the book resumes from the saved
    /// position. Rendered with a secondary tint + smaller glyph so it reads
    /// as the low-frequency destructive action, not a transport control.
    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(14)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .tint(.secondary)
        .accessibilityLabel(Strings.Generic.stopAudiobook)
    }

    /// Swipe DOWN on the bar → collapse to the pill. Mirrors the full
    /// player's `swipeDownToMinimize` shape (drag with a directional +
    /// horizontal-drift threshold) but drives `presenter.collapse()` instead
    /// of `minimize()`. Threshold is smaller than the full player's 100pt
    /// because the mini-bar is only ~60pt tall — a 100pt swipe would overshoot
    /// the bar entirely before registering.
    private var swipeDownToCollapse: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onEnded { value in
                handleCollapseDragEnd(translation: value.translation)
            }
    }

    /// Test-visible drag-end handler — takes a raw `CGSize` so unit tests can
    /// drive the boundary without spinning up a real `DragGesture`. Collapses
    /// (honoring reduce-motion) iff the drag clears the pure `shouldCollapse`
    /// threshold.
    func handleCollapseDragEnd(translation: CGSize) {
        guard Self.shouldCollapse(translation: translation) else { return }
        if UIAccessibility.isReduceMotionEnabled {
            presenter.collapse()
        } else {
            withAnimation(PalaceMotion.standard) { presenter.collapse() }
        }
    }

    /// Downward-drag threshold (points) past which a swipe collapses the bar.
    /// Smaller than the full player's 100pt (the bar is short).
    static let collapseSwipeDownThreshold: CGFloat = 44

    /// Max horizontal drift before a downward swipe stops counting as
    /// "vertical" — filters diagonal scrolls, same contract as the full
    /// player's `minimizeSwipeMaxHorizontalDrift`.
    static let collapseSwipeMaxHorizontalDrift: CGFloat = 60

    /// Pure collapse decision: a downward drag past the threshold with limited
    /// horizontal drift. Extracted `static` so the `&&` / `>` / `<` operators
    /// are mutation-testable without a SwiftUI host — the view body is opaque.
    static func shouldCollapse(translation: CGSize) -> Bool {
        return translation.height > collapseSwipeDownThreshold
            && abs(translation.width) < collapseSwipeMaxHorizontalDrift
    }

    /// Fires the hard dismiss. `stopPlayback` is `async`, so we hop onto a
    /// `Task` (the `@MainActor` context is preserved). The manager's
    /// teardown clears the presenter, so no explicit UI mutation is needed
    /// here — the bar/pill drop when `hasActiveSession` flips false.
    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        Task { await performDismiss() }
    }

    /// The awaitable teardown the `✕` button drives. Split from `dismiss()`
    /// (which only wraps it in a `Task` + double-tap guard) so tests can
    /// `await` it directly and pin the exact arguments — `persistFinalPosition:
    /// true` so re-opening resumes, `dismissPhoneUI: true` so the phone chrome
    /// tears down.
    func performDismiss() async {
        await audiobookSession.stopPlayback(dismissPhoneUI: true, persistFinalPosition: true)
    }

    private var scrubber: some View {
        ProgressView(value: progress.playbackProgress.isFinite ? min(max(progress.playbackProgress, 0), 1) : 0,
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
        guard let position = progress.currentLocation else {
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
