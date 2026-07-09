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

    /// The drawer grab handle — the standard iOS "this is draggable" affordance,
    /// centered at the top of the bar. It makes both directions discoverable:
    /// pull UP to open the full player, pull DOWN to collapse to the pill. A bare
    /// tap-to-open (the prior behavior) gave no hint the bar was interactive; the
    /// handle + the drawer drag fix that. Also independently tappable/draggable.
    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .onTapGesture { expandWithMotionPreference() }
            .gesture(drawerDrag)
            .accessibilityHidden(true)
    }

    private var miniPlayerChrome: some View {
        VStack(spacing: 0) {
            grabber
            HStack(spacing: 12) {
                // The drawer zone: cover + title. Tap OR pull it — up expands to
                // the full player, down collapses to the pill. The drawer drag
                // lives HERE (and on the grabber), deliberately NOT over the
                // transport/dismiss buttons: a container `DragGesture` spanning
                // the buttons intermittently swallowed their taps (the root of
                // the "✕ sometimes does nothing" bug). Buttons now own their taps.
                HStack(spacing: 12) {
                    coverImage
                    titleAndTimeStack
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .onTapGesture { expandWithMotionPreference() }
                .gesture(drawerDrag)
                .accessibilityHidden(true)

                skipBackButton
                playPauseButton
                skipForwardButton
                dismissButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 8)
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
            withAnimation(PalaceMotion.standard) { presenter.expand() }
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

    /// The hard-dismiss control. Unlike the drawer collapse (which tucks the bar
    /// into the pill and keeps audio playing), this ENDS the session:
    /// `stopPlayback(dismissPhoneUI: true, persistFinalPosition: true)` saves the
    /// final position, tears down the toolkit player, and drops both the mini-bar
    /// and the pill. Re-opening the book resumes from the saved position.
    ///
    /// Rendered as a filled circular "close" chip (SF `xmark.circle.fill`) rather
    /// than a bare glyph: the circle reads unambiguously as a distinct close
    /// affordance — set apart from the transport glyphs beside it — instead of a
    /// fourth, cryptic transport control. 44pt hit target.
    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.Generic.stopAudiobook)
    }

    /// The unified drawer gesture: a vertical drag that resolves like a bottom
    /// drawer — pull UP past the threshold to open the full player, pull DOWN to
    /// collapse to the pill, small drags snap back. Attached to the grabber +
    /// cover/title zone only (never the transport/dismiss buttons, so their taps
    /// stay reliable). Replaces the prior down-only `swipeDownToCollapse` and the
    /// tap-only expand: the bar now reads and behaves as a draggable drawer.
    private var drawerDrag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onEnded { value in
                handleDrawerDragEnd(translation: value.translation)
            }
    }

    /// Test-visible drawer drag-end handler — takes a raw `CGSize` so unit tests
    /// can drive the up/down boundaries without a real `DragGesture`. Both
    /// transitions honor reduce-motion and animate with `PalaceMotion.standard`
    /// (the app's motion system), matching the full player.
    func handleDrawerDragEnd(translation: CGSize) {
        switch Self.drawerAction(translation: translation) {
        case .expand:
            expandWithMotionPreference()
        case .collapse:
            if UIAccessibility.isReduceMotionEnabled {
                presenter.collapse()
            } else {
                withAnimation(PalaceMotion.standard) { presenter.collapse() }
            }
        case .none:
            break
        }
    }

    /// Which way a drawer drag resolves.
    enum DrawerAction: Equatable { case expand, collapse, none }

    /// Pure drawer decision: an UP drag past `expandSwipeUpThreshold` expands, a
    /// DOWN drag past `collapseSwipeDownThreshold` collapses, both gated on
    /// limited horizontal drift; anything else snaps back. Extracted `static` so
    /// the thresholds / comparisons are mutation-testable without a SwiftUI host.
    static func drawerAction(translation: CGSize) -> DrawerAction {
        guard abs(translation.width) < collapseSwipeMaxHorizontalDrift else { return .none }
        if translation.height <= -expandSwipeUpThreshold { return .expand }
        if translation.height >= collapseSwipeDownThreshold { return .collapse }
        return .none
    }

    /// Upward-drag threshold (points) past which the drawer opens the full
    /// player. Symmetric with `collapseSwipeDownThreshold`.
    static let expandSwipeUpThreshold: CGFloat = 44

    /// Test-visible drag-end handler — takes a raw `CGSize` so unit tests can
    /// drive the boundary without spinning up a real `DragGesture`. Collapses
    /// (honoring reduce-motion) iff the drag clears the pure `shouldCollapse`
    /// threshold. Retained for the collapse-path tests; `handleDrawerDragEnd` is
    /// the production entry point (it also handles the expand direction).
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

    /// Fires the hard dismiss. Two-part so the tap ALWAYS has an instant visible
    /// effect regardless of how long the async teardown takes:
    ///   1. Optimistically clear the presenter NOW — `hasActiveSession` flips
    ///      false synchronously, so the bar/pill drop on this frame. This is what
    ///      makes the control feel reliable; the prior version only hid the bar
    ///      after the async `stopPlayback` finished, so any delay (or a nil
    ///      `currentBook` skipping the manager's own clear) left the bar sitting
    ///      there with `isDismissing` stuck `true` — the "✕ does nothing" bug.
    ///   2. Run the real teardown (save position, tear down the toolkit player)
    ///      on a `Task`. `stopPlayback` re-clears the presenter idempotently.
    /// Animated with `PalaceMotion.standard` (reduce-motion aware) so the drop
    /// matches the drawer's motion.
    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        if UIAccessibility.isReduceMotionEnabled {
            presenter.clearActiveSession()
        } else {
            withAnimation(PalaceMotion.standard) { presenter.clearActiveSession() }
        }
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
