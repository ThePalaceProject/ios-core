//
//  AudiobookMorphingPlayerView.swift
//  Palace
//
//  A CUSTOM audiobook player that is ONE view reflowing between a full-screen
//  layout and a compact mini bar — Apple-Music style — rather than crossfading
//  two separate views. The cover art carries a `matchedGeometryEffect`, so on
//  expand/minimize it shrinks and slides between the two positions as the SAME
//  element (no crossfade), which is what makes it read as one view being pulled
//  down into a smaller one.
//
//  Why custom (not the toolkit `AudiobookPlayerView`): the toolkit view owns a
//  fixed full-screen layout we can't reflow, so morphing it into a mini bar is
//  impossible — any "resize" ends up crossfading it with a separate bar, which
//  reads as two views. This view is fully ours, driven off the presenter's
//  published state + the `AudiobookSessionManaging` actions, so it can genuinely
//  morph. The toolkit view is kept mounted-but-hidden elsewhere
//  (`AppTabHostView`) purely to preserve playback wiring.
//
//  Scope (first cut): cover, title/author, chapter label, a DISPLAY-ONLY
//  progress scrubber (no seek — the protocol exposes none, same as the old mini
//  bar), 30s skips, play/pause, a playback-rate chip, and a small Stop. Sleep
//  timer / bookmarks / arbitrary seek are deferred (no protocol surface yet).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVKit
import PalaceAudiobookToolkit
import SwiftUI
import UIKit

@MainActor
struct AudiobookMorphingPlayerView: View {

    @ObservedObject var presenter: AudiobookSessionPresenter
    @ObservedObject var progress: AudiobookPlaybackProgress
    let audiobookSession: AudiobookSessionManaging

    /// Namespace for the cover's `matchedGeometryEffect` — the single element
    /// that morphs between the full and mini layouts.
    @Namespace private var morphNamespace

    /// Current playback rate, seeded from the session on expand so the speed
    /// chip shows the real persisted rate (not a hardcoded "1.0×") and the
    /// speed sheet opens at the correct value.
    @State private var currentRate: PlaybackRate = .normalTime

    /// Presents the toolkit's Chapters + Bookmarks list (`AudiobookNavigationView`).
    @State private var showChaptersBookmarks = false

    /// Presents the ported stepped speed picker (`PlaybackSpeedSheet`).
    @State private var showSpeedSheet = false

    /// Live scrubber position + whether the user is dragging it. While dragging,
    /// the bar tracks the finger (not playback); on release it seeks.
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    /// Loading-timeout state: while `!isLoaded`, a 30s timer arms; on expiry we
    /// flip to the error+retry overlay (mirrors toolkit `loadingTimedOut`).
    @State private var loadingTimedOut = false

    /// Transient toast (bookmark-added / playback error), mirroring the toolkit's
    /// `bookmarkAddedToastView` + `showToast` delay behavior.
    @State private var toastText = ""
    @State private var showToast = false

    /// VoiceOver focus target — moved to the title when the full player expands
    /// (mirrors toolkit `isTitleFocused`).
    @AccessibilityFocusState private var isTitleFocused: Bool

    // MARK: - Layout constants

    private static let miniBarHeight: CGFloat = 74
    private static let miniMargin: CGFloat = 8
    private static let tabBarHeight: CGFloat = 49
    private static let coverMatchID = "audiobookCover"

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let expanded = presenter.isPlayerExpanded
            let hidden = presenter.isReaderActive
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            let landscape = Self.isLandscapePhone(size: geo.size)

            card(expanded: expanded, screenHeight: geo.size.height, landscape: landscape)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                // Reader: slide the whole card off-screen WITHOUT unmounting, so
                // audio keeps playing with no chrome.
                .offset(y: hidden ? geo.size.height + 200 : 0)
                .animation(reduceMotion ? nil : PalaceMotion.emphasized, value: expanded)
                .animation(reduceMotion ? nil : PalaceMotion.standard, value: hidden)
        }
        .ignoresSafeArea()
    }

    /// The single morphing card: full-screen when expanded, a rounded mini bar
    /// floating above the tab bar when minimized.
    @ViewBuilder
    private func card(expanded: Bool, screenHeight: CGFloat, landscape: Bool) -> some View {
        ZStack(alignment: .top) {
            Color(.systemBackground)
            if expanded {
                fullContent(landscape: landscape)
            } else {
                miniContent
            }
        }
        .frame(height: expanded ? screenHeight : Self.miniBarHeight)
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 16, style: .continuous))
        .shadow(color: .black.opacity(expanded ? 0 : 0.18),
                radius: expanded ? 0 : 10, y: -2)
        .padding(.horizontal, expanded ? 0 : Self.miniMargin)
        // Float the mini card clear of the tab bar + home indicator. Read the
        // real bottom inset from the window (the GeometryReader ignores safe area
        // for the full-bleed expanded state, so its inset is 0).
        .padding(.bottom, expanded ? 0 : bottomSafeInset + Self.tabBarHeight + Self.miniMargin)
        // No `.contentShape` on the padded frame: when minimized, the bottom
        // padding sits OVER the tab bar, and a rectangular content-shape there
        // swallowed the tab bar's taps. The mini bar's own `Color` fill (the
        // `miniBarHeight` card) is the only hit region; the padding + the empty
        // area above pass touches through to the tabs.
    }

    // MARK: - Full layout

    @ViewBuilder
    private func fullContentLayout(landscape: Bool) -> some View {
        if landscape {
            fullContentLandscape
        } else {
            fullContentPortrait
        }
    }

    @ViewBuilder
    private func fullContent(landscape: Bool) -> some View {
        fullContentLayout(landscape: landscape)
        // Pull DOWN on the grabber or the cover to minimize — the drag lives on
        // those two zones only (see `grabber` + the cover below), NOT the whole
        // player. A container drag over the seek Slider and the transport/bottom
        // buttons stole/propagated their taps (scrub jitter; the speed chip
        // "dismissing" the player). Keeping the drag off the controls fixes that.
        .fullScreenCover(isPresented: $showChaptersBookmarks) {
            if let model = presenter.playbackModel {
                NavigationStack { AudiobookNavigationView(model: model) }
            }
        }
        // Ported stepped speed picker (0.5×–3.0× with ± steppers + presets).
        .sheet(isPresented: $showSpeedSheet) {
            PlaybackSpeedSheet(playbackRate: speedBinding)
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.hidden)
        }
        // Loading spinner → 30s timeout → error+retry, over the whole player.
        .overlay { loadingOverlay }
        // Transient bookmark-added / playback-error toast.
        .overlay(alignment: .bottom) { toastOverlay }
        .accessibilityElement(children: .contain)
        .onAppear {
            currentRate = audiobookSession.currentPlaybackRate
            // Announce the screen transition + move VoiceOver focus to the title
            // (mirrors toolkit AudiobookPlayerView.onAppear).
            NotificationCenter.default.post(
                name: Notification.Name("TPPAccessibilityScreenTransition"),
                object: nil
            )
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                isTitleFocused = true
            }
        }
        .onChange(of: presenter.toastMessage) { _, newValue in
            if let msg = newValue, !msg.isEmpty { presentToast(msg) }
        }
    }

    private var fullContentPortrait: some View {
        VStack(spacing: 0) {
            topControls

            titleAuthorFull
                .padding(.top, 8)
                .padding(.horizontal, 24)

            seekBar
                .padding(.horizontal, 24)
                .padding(.top, 14)

            Spacer(minLength: 16)

            coverArt
                .frame(maxWidth: 320)
                .padding(.horizontal, 40)

            downloadBar
                .padding(.horizontal, 24)
                .padding(.top, 12)

            Spacer(minLength: 16)

            transportRow
                .padding(.top, 8)

            bottomControls
                .padding(.top, 22)
                .padding(.bottom, bottomSafeInset + 16)
        }
        .frame(maxWidth: .infinity)
    }

    /// iPhone-landscape branch: cover on the left, title/controls on the right,
    /// bottom-control panel spanning underneath (mirrors toolkit `landscapeLayout`).
    private var fullContentLandscape: some View {
        VStack(spacing: 0) {
            topControls

            HStack(spacing: 20) {
                VStack(spacing: 8) {
                    coverArt
                        .frame(maxHeight: .infinity)
                    downloadBar
                }
                .frame(maxWidth: .infinity)
                .padding(.leading, 20)

                VStack(spacing: 8) {
                    titleAuthorFull
                    seekBar
                    Spacer(minLength: 8)
                    transportRow
                }
                .frame(maxWidth: .infinity)
                .padding(.trailing, 20)
            }
            .padding(.top, 4)

            bottomControls
                .padding(.top, 8)
                .padding(.bottom, bottomSafeInset + 12)
        }
        .frame(maxWidth: .infinity)
    }

    /// Shared cover art lockup used by both orientations: matchedGeometry morph
    /// target, a subtle play/pause scale pulse, and the pull-down-to-minimize
    /// drag zone.
    private var coverArt: some View {
        coverImageOrPlaceholder
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            .matchedGeometryEffect(id: Self.coverMatchID, in: morphNamespace)
            // Cosmetic pulse: shrink slightly while paused (toolkit parity).
            .scaleEffect(presenter.isPlaying ? 1.0 : 0.94)
            .animation(
                UIAccessibility.isReduceMotionEnabled ? nil
                    : .spring(response: 0.35, dampingFraction: 0.7),
                value: presenter.isPlaying
            )
            // Pull the cover DOWN to minimize (a large, safe drag zone).
            .contentShape(Rectangle())
            .gesture(minimizeDrag)
            .accessibilityLabel(Strings.Generic.bookCover)
    }

    /// Top row: a centered grab handle (pull DOWN to minimize) + a trailing
    /// Chapters/Bookmarks (Table-of-Contents) button, mirroring the original
    /// player's top-trailing TOC control. No chevron-down (per design).
    private var topControls: some View {
        ZStack {
            grabber
            HStack {
                Spacer()
                Button { showChaptersBookmarks = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .tint(.primary)
                .accessibilityLabel(Strings.Generic.tableOfContents)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, topSafeInset + 8)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 40, height: 5)
            // Wider invisible hit zone so the pull-down is easy to grab.
            .frame(width: 140, height: 28)
            .contentShape(Rectangle())
            .gesture(minimizeDrag)
            .accessibilityHidden(true)
    }

    /// Scrubbable seek bar. While the user drags, `scrubValue` tracks the finger
    /// and playback ticks are ignored; on release it seeks via
    /// `audiobookSession.seek(to:)` (toolkit `seekWithSlider`).
    private var seekBar: some View {
        VStack(spacing: 4) {
            Slider(value: $scrubValue, in: 0...1) { editing in
                isScrubbing = editing
                if !editing {
                    audiobookSession.seek(to: scrubValue)
                    // Seek-commit haptic (toolkit parity).
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .tint(.accentColor)
            .accessibilityLabel(Strings.Generic.playbackPosition)
            .accessibilityValue(seekAccessibilityValue)
            // Row under the bar: chapter elapsed · chapter name · chapter time-left
            // (mirrors toolkit `playheadOffsetText` / `chapterTitle` / `timeLeftText`).
            HStack(spacing: 8) {
                Text(chapterElapsedString)
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel(Strings.Generic.timeElapsedLabel(chapterElapsedString))
                Spacer(minLength: 8)
                Text(audiobookSession.currentChapter?.title ?? presenter.currentBook?.title ?? "")
                    .font(.subheadline).fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(chapterRemainingString)
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel(Strings.Generic.timeRemainingLabel(chapterRemainingString))
            }
        }
        .onAppear { scrubValue = clampedProgress }
        .onChange(of: clampedProgress) { _, newValue in
            if !isScrubbing { scrubValue = newValue }
        }
    }

    private var titleAuthorFull: some View {
        VStack(spacing: 4) {
            Text(presenter.currentBook?.title ?? "")
                .font(.title3).fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityFocused($isTitleFocused)
            if let authors = presenter.currentBook?.authors, !authors.isEmpty {
                Text(authors)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            let remaining = wholeBookRemainingString
            if !remaining.isEmpty {
                Text(remaining)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private var transportRow: some View {
        HStack(spacing: 36) {
            transportButton("gobackward.30", label: Strings.Generic.skipBack30, size: 32) {
                audiobookSession.skipBack()
            }
            Button(action: { audiobookSession.togglePlayPause() }) {
                // Dark circle + light glyph, matching the original (not a white
                // filled symbol).
                ZStack {
                    Circle().fill(Color(.systemGray5))
                    Image(systemName: presenter.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 72, height: 72)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presenter.isPlaying ? Strings.Generic.pauseAudiobook : Strings.Generic.playAudiobook)
            transportButton("goforward.30", label: Strings.Generic.skipForward30, size: 32) {
                audiobookSession.skipForward()
            }
        }
    }

    /// Bottom control row, mirroring the original player: playback-speed chip ·
    /// AirPlay route picker · sleep-timer menu · Bookmarks button (opens the same
    /// Chapters/Bookmarks list).
    private var bottomControls: some View {
        HStack(spacing: 0) {
            // Speed chip → opens the stepped speed sheet (no longer cycle-only).
            Button { showSpeedSheet = true } label: {
                Text(currentRate.displayLabel)
                    .font(.subheadline).fontWeight(.medium)
                    .frame(minWidth: 52)
                    .padding(.vertical, 6).padding(.horizontal, 12)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.Generic.playbackSpeedValue(currentRate.displayLabel))

            Spacer()

            AirPlayRoutePicker()
                .frame(width: 44, height: 44)
                .accessibilityLabel(Strings.Generic.airplay)

            Menu {
                ForEach(SleepTimerTriggerAt.allCases, id: \.self) { trigger in
                    Button(trigger.displayTitle) {
                        audiobookSession.setSleepTimer(trigger)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: audiobookSession.sleepTimerIsActive ? "moon.fill" : "moon")
                        .font(.system(size: 18, weight: .medium))
                    if audiobookSession.sleepTimerIsActive {
                        Text(AudiobookMiniPlayerView.formatTime(audiobookSession.sleepTimerRemaining))
                            .font(.caption).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .tint(.primary)
            .accessibilityLabel(Strings.Generic.sleepTimer)

            // Bottom bookmark control ADDS a bookmark (TOC/list stays reachable
            // via the top-trailing list button).
            Button { addBookmarkFromControl() } label: {
                Image(systemName: "bookmark")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .accessibilityLabel(Strings.Generic.addBookmark)
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Download bar (toolkit `downloadProgressView` parity)

    @ViewBuilder
    private var downloadBar: some View {
        if presenter.isDownloading {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.15)).frame(height: 4)
                            Capsule().fill(Color.accentColor)
                                .frame(width: max(4, geo.size.width * CGFloat(presenter.overallDownloadProgress)), height: 4)
                                .animation(.easeInOut(duration: 0.3), value: presenter.overallDownloadProgress)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 4)
                    Text("\(Int(presenter.overallDownloadProgress * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                        .monospacedDigit()
                }
                Text(Strings.Generic.audiobookDownloading)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Strings.Generic.audiobookDownloading), \(Int(presenter.overallDownloadProgress * 100))%")
        }
    }

    // MARK: - Loading overlay (toolkit `LoadingView` / `LoadingErrorView` parity)

    @ViewBuilder
    private var loadingOverlay: some View {
        if !audiobookSession.isLoaded {
            if loadingTimedOut {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40)).foregroundStyle(.yellow)
                        Text(Strings.Generic.audiobookLoadErrorTitle)
                            .foregroundStyle(.white).font(.headline)
                        Text(Strings.Generic.audiobookLoadErrorMessage)
                            .foregroundStyle(.white).multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            loadingTimedOut = false
                            audiobookSession.play()
                        } label: {
                            Text(Strings.Generic.audiobookRetry)
                                .fontWeight(.semibold).foregroundStyle(.black)
                                .padding(.horizontal, 32).padding(.vertical, 10)
                                .background(Color.white).cornerRadius(8)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            } else {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(2)
                        Text(Strings.Generic.audiobookLoading)
                            .foregroundStyle(.white).padding(.top, 8)
                    }
                }
                .onAppear {
                    // Arm the 30s timeout; reset on (re)appear (mirrors toolkit).
                    loadingTimedOut = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        if !audiobookSession.isLoaded {
                            loadingTimedOut = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - Toast overlay (toolkit `bookmarkAddedToastView` parity)

    @ViewBuilder
    private var toastOverlay: some View {
        if showToast {
            HStack(spacing: 10) {
                Image(systemName: toastText.localizedCaseInsensitiveContains("error")
                        || toastText == Strings.Generic.bookmarkAddFailed
                      ? "exclamationmark.circle.fill" : "bookmark.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(toastText)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
            )
            .shadow(color: .black.opacity(0.3), radius: 16, y: 4)
            .padding(.horizontal, 20)
            .padding(.bottom, bottomSafeInset + 110)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
        }
    }

    private func transportButton(_ system: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: {
            // Skip-button haptic (toolkit parity).
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            Image(systemName: system)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .tint(.accentColor)
        .accessibilityLabel(label)
    }

    // MARK: - Mini layout

    private var miniContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                coverImageOrPlaceholder
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .matchedGeometryEffect(id: Self.coverMatchID, in: morphNamespace)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presenter.currentBook?.title ?? "")
                        .font(.subheadline).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.tail)
                    if let authors = presenter.currentBook?.authors, !authors.isEmpty {
                        Text(authors)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                // Tap the cover/title zone to expand.
                .contentShape(Rectangle())
                .onTapGesture { expand() }

                Spacer(minLength: 2)

                Button(action: { audiobookSession.skipBack() }) {
                    Image(systemName: "gobackward.30")
                        .font(.system(size: 18, weight: .regular))
                        .frame(width: 40, height: 44)
                }
                .buttonStyle(.plain).tint(.primary)
                .accessibilityLabel(Strings.Generic.skipBack30)

                Button(action: { audiobookSession.togglePlayPause() }) {
                    Image(systemName: presenter.isPlaying ? "pause.fill" : "play.fill")
                        .resizable().aspectRatio(contentMode: .fit)
                        .padding(10).frame(width: 42, height: 42)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain).tint(.accentColor)
                .accessibilityLabel(presenter.isPlaying ? Strings.Generic.pauseAudiobook : Strings.Generic.playAudiobook)

                Button(action: { audiobookSession.skipForward() }) {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 18, weight: .regular))
                        .frame(width: 40, height: 44)
                }
                .buttonStyle(.plain).tint(.primary)
                .accessibilityLabel(Strings.Generic.skipForward30)

                Button(action: stop) {
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
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ProgressView(value: clampedProgress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(height: 2)
                .accessibilityHidden(true)
        }
        // Tap anywhere else / pull up on the bar → expand.
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        .gesture(expandDrag)
    }

    // MARK: - Shared cover

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

    // MARK: - Gestures

    /// Pull DOWN on the full player past the threshold → minimize.
    private var minimizeDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onEnded { value in
                if value.translation.height > 80,
                   abs(value.translation.width) < 80 {
                    minimize()
                }
            }
    }

    /// Pull UP on the mini bar past the threshold → expand.
    private var expandDrag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onEnded { value in
                if value.translation.height < -30,
                   abs(value.translation.width) < 60 {
                    expand()
                }
            }
    }

    // MARK: - Actions

    private func expand() {
        setExpanded(true)
    }

    private func minimize() {
        setExpanded(false)
    }

    private func setExpanded(_ value: Bool) {
        if UIAccessibility.isReduceMotionEnabled {
            value ? presenter.expand() : presenter.minimize()
        } else {
            withAnimation(PalaceMotion.emphasized) {
                value ? presenter.expand() : presenter.minimize()
            }
        }
    }

    private func stop() {
        Task { await audiobookSession.stopPlayback(dismissPhoneUI: true, persistFinalPosition: true) }
    }

    /// Two-way binding driving the ported speed sheet: writes both the local
    /// chip state (immediate label update) and the session's playback rate,
    /// posting a VoiceOver announcement as the rate changes.
    private var speedBinding: Binding<PlaybackRate> {
        Binding(
            get: { currentRate },
            set: { newRate in
                guard newRate != currentRate else { return }
                currentRate = newRate
                audiobookSession.setPlaybackRate(newRate)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: Strings.Generic.playbackSpeedValue(newRate.displayLabel)
                )
            }
        )
    }

    /// Adds a bookmark at the current position and surfaces a toast for the
    /// success / failure outcome (toolkit `addBookmark` + `showToast` parity).
    private func addBookmarkFromControl() {
        audiobookSession.addBookmark { error in
            DispatchQueue.main.async {
                presentToast(error == nil
                    ? Strings.Generic.bookmarkAdded
                    : (error?.localizedDescription.isEmpty == false
                        ? error!.localizedDescription
                        : Strings.Generic.bookmarkAddFailed))
            }
        }
    }

    private func presentToast(_ text: String) {
        toastText = text
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.25)) { showToast = false }
        }
    }

    /// iPhone in a landscape aspect. iPad keeps the portrait lockup.
    static func isLandscapePhone(size: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone && size.width > size.height
    }

    // MARK: - Derived

    private var clampedProgress: Double {
        progress.playbackProgress.isFinite ? min(max(progress.playbackProgress, 0), 1) : 0
    }

    /// Chapter-relative elapsed timecode (seconds from the start of the current
    /// chapter) — mirrors toolkit `playheadOffsetText`.
    private var chapterElapsedString: String {
        AudiobookMiniPlayerView.formatTime(progress.chapterOffset)
    }

    /// Chapter-relative time-left timecode — mirrors toolkit `timeLeftText`.
    private var chapterRemainingString: String {
        "-" + AudiobookMiniPlayerView.formatTime(max(0, progress.chapterTimeLeft))
    }

    /// Spoken value for the seek slider: percent through the book plus the
    /// chapter elapsed timecode.
    private var seekAccessibilityValue: String {
        "\(Int(clampedProgress * 100))%, \(chapterElapsedString)"
    }

    // MARK: - Safe-area insets (window, since the overlay ignores safe area)

    private var topSafeInset: CGFloat { Self.keyWindowInsets.top }
    private var bottomSafeInset: CGFloat { Self.keyWindowInsets.bottom }

    private static var keyWindowInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
    }

    /// Whole-book remaining, phrased like the original ("18 hr 06 min remaining").
    private var wholeBookRemainingString: String {
        guard let position = progress.currentLocation else { return "" }
        let total = position.tracks.totalDuration
        let elapsed = total * clampedProgress
        let remaining = max(0, total - elapsed)
        let hrs = Int(remaining) / 3600
        let mins = (Int(remaining) % 3600) / 60
        if hrs > 0 { return String(format: "%d hr %02d min remaining", hrs, mins) }
        return String(format: "%d min remaining", mins)
    }
}

/// SwiftUI wrapper for the system AirPlay/route picker, matching the original
/// player's cast control.
private struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = .label
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - PlaybackSpeedSheet

/// Stepped playback-speed picker ported into the app from the toolkit's
/// internal `SpeedSliderSheet` (0.5×–3.0× slider + ± steppers + preset chips).
/// The toolkit view is module-internal, so its behavior is re-implemented here
/// against the public `PlaybackRate` API (`presets`, `nearest`, `convert`,
/// `displayLabel`).
@MainActor
private struct PlaybackSpeedSheet: View {
    @Binding var playbackRate: PlaybackRate

    @State private var sliderValue: Double = 1.0

    private let step: Double = 0.05
    private let minRate: Double = 0.5
    private let maxRate: Double = 3.0

    private var speedLabel: String {
        PlaybackRate.nearest(to: Float(sliderValue)).displayLabel
    }
    private var atMinimum: Bool { sliderValue <= minRate }
    private var atMaximum: Bool { sliderValue >= maxRate }

    var body: some View {
        VStack(spacing: 28) {
            headerRow
            sliderRow
            presetChips
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.Generic.playbackSpeed)
        .onAppear { sliderValue = Double(PlaybackRate.convert(rate: playbackRate)) }
        .onChange(of: sliderValue) { _, newValue in
            let nearest = PlaybackRate.nearest(to: Float(newValue))
            if nearest != playbackRate {
                playbackRate = nearest
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text(Strings.Generic.playbackSpeed)
                .font(.headline)
            Spacer()
            Text(speedLabel)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.Generic.playbackSpeedValue(speedLabel))
    }

    private var sliderRow: some View {
        HStack(spacing: 16) {
            stepButton(systemName: "minus", label: Strings.Generic.decreaseSpeed, isDisabled: atMinimum, action: stepDown)
            Slider(value: $sliderValue, in: minRate...maxRate, step: step)
                .tint(.accentColor)
                .accessibilityLabel(Strings.Generic.playbackSpeed)
                .accessibilityValue(speedLabel)
            stepButton(systemName: "plus", label: Strings.Generic.increaseSpeed, isDisabled: atMaximum, action: stepUp)
        }
    }

    private func stepButton(systemName: String, label: String, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.secondary.opacity(isDisabled ? 0.05 : 0.15)))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }

    private var presetChips: some View {
        HStack(spacing: 8) {
            ForEach(PlaybackRate.presets, id: \.rawValue) { preset in
                presetChip(for: preset)
            }
        }
        .accessibilityLabel(Strings.Generic.playbackSpeed)
    }

    private func presetChip(for preset: PlaybackRate) -> some View {
        let multiplier = PlaybackRate.convert(rate: preset)
        let isSelected = abs(sliderValue - Double(multiplier)) < 0.001
        return Button {
            withAnimation(.easeOut(duration: 0.1)) { sliderValue = Double(multiplier) }
        } label: {
            Text(preset.displayLabel)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.primary : Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.displayLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func stepDown() {
        withAnimation(.easeOut(duration: 0.1)) {
            sliderValue = max(minRate, ((sliderValue - step) * 100).rounded() / 100)
        }
    }
    private func stepUp() {
        withAnimation(.easeOut(duration: 0.1)) {
            sliderValue = min(maxRate, ((sliderValue + step) * 100).rounded() / 100)
        }
    }
}
