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

    /// Live vertical translation of the whole card while the user pulls DOWN on
    /// the grabber/cover to minimize. During the drag the card tracks the finger
    /// (revealing the tab content behind it); on release it either animates to
    /// minimized (past threshold / flung down) or springs back to expanded.
    /// Reset to 0 on every release. Only applied while expanded.
    @State private var dragTranslation: CGFloat = 0

    /// Drives the first-open slide/fade-in. Starts `false` so a freshly-mounted
    /// card renders off-screen + transparent, then animates up on `.onAppear`
    /// for a clean appear (fixes the choppy pop-in on a cold open). Persists
    /// `true` for the view's lifetime, so subsequent expand/mini cycles use the
    /// matchedGeometry morph, not this appear animation.
    @State private var hasAppeared = false

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

    // MARK: - Adaptive control metrics

    /// Adaptive sizing for the transport row + bottom control chips, ported
    /// verbatim from the toolkit `AudiobookPlayerView` (`controlPanelView`
    /// ~L500-506 + `playbackControlsView` ~L472/491). Three tiers keyed off
    /// `isNarrowScreen` (`width < 370`, SE/Mini) and iPhone-landscape. Pure
    /// value type so the tier math is unit-testable without a SwiftUI host.
    struct ControlMetrics: Equatable {
        let landscape: Bool
        let narrow: Bool
        let chipHeight: CGFloat
        let fontSize: CGFloat
        let iconSize: CGFloat
        let chipPadH: CGFloat
        let outerPadH: CGFloat
        let chipSpacing: CGFloat
        let transportSpacing: CGFloat
        let transportHeight: CGFloat
        let playButton: CGFloat
        let playGlyph: CGFloat
        let skipGlyph: CGFloat

        init(width: CGFloat, landscape: Bool) {
            let narrow = width < 370
            self.landscape = landscape
            self.narrow = narrow
            // controlPanelView tiers (toolkit): standard 40/15/19/14/20/12,
            // narrow 34/12/15/10/12/6, landscape 34/13/16/12/16/8.
            chipHeight  = landscape ? 34 : (narrow ? 34 : 40)
            fontSize    = landscape ? 13 : (narrow ? 12 : 15)
            iconSize    = landscape ? 16 : (narrow ? 15 : 19)
            chipPadH    = landscape ? 12 : (narrow ? 10 : 14)
            outerPadH   = landscape ? 16 : (narrow ? 12 : 20)
            chipSpacing = landscape ? 8  : (narrow ? 6  : 12)
            // playbackControlsView (toolkit): HStack spacing 40 / landscape 25,
            // frame height 72 / landscape 56. Play glyph + skip glyph scaled to
            // fit the row (compact-width equivalents of the toolkit sizes).
            transportSpacing = landscape ? 25 : 40
            transportHeight  = landscape ? 56 : 72
            playButton = landscape ? 56 : 72
            playGlyph  = landscape ? 34 : 44
            skipGlyph  = landscape ? 28 : 34
        }
    }

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

            card(expanded: expanded, size: geo.size, landscape: landscape)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                // Reader hide + first-open slide-in + interactive pull-down are
                // all folded into a single vertical offset (see `cardOffsetY`).
                .offset(y: cardOffsetY(expanded: expanded, hidden: hidden, screenHeight: geo.size.height))
                // Fade the card in on first mount together with the slide-up.
                .opacity(hasAppeared ? 1 : 0)
                // The morph (expand ⇄ mini), first-open, and reader-hide ALL ride
                // the one player-morph spring so the cover matchedGeometry, the
                // controls, and the card corner-radius settle on the same curve.
                // No `.animation` is keyed to `dragTranslation` — the interactive
                // pull-down therefore tracks the finger 1:1 (its settle is driven
                // explicitly in `settleDrag`), which is the zero-latency path.
                .animation(reduceMotion ? nil : PalaceMotion.playerMorph, value: expanded)
                .animation(reduceMotion ? nil : PalaceMotion.playerMorph, value: hidden)
                .animation(reduceMotion ? nil : PalaceMotion.playerMorph, value: hasAppeared)
                .onAppear {
                    // The `.animation(value: hasAppeared)` above drives the slide+
                    // fade on the same spring family (gated for reduce motion), so
                    // just flip the flag — no separate `withAnimation` transaction.
                    guard !hasAppeared else { return }
                    hasAppeared = true
                }
        }
        .ignoresSafeArea()
    }

    /// Total vertical offset of the card, composing three independent effects:
    ///   - reader hide: slide fully off-screen (audio keeps playing, no unmount),
    ///   - first-open appear: start one screen below and slide up on `.onAppear`,
    ///   - interactive pull-down: follow the finger while dragging (expanded only).
    private func cardOffsetY(expanded: Bool, hidden: Bool, screenHeight: CGFloat) -> CGFloat {
        let readerOffset: CGFloat = hidden ? screenHeight + 200 : 0
        let appearOffset: CGFloat = hasAppeared ? 0 : screenHeight
        let dragOffset: CGFloat = expanded ? dragTranslation : 0
        return readerOffset + appearOffset + dragOffset
    }

    /// The single morphing card: full-screen when expanded, a rounded mini bar
    /// floating above the tab bar when minimized.
    @ViewBuilder
    private func card(expanded: Bool, size: CGSize, landscape: Bool) -> some View {
        ZStack(alignment: .top) {
            Color(.systemBackground)
            if expanded {
                fullContent(size: size, landscape: landscape)
            } else {
                miniContent
            }
        }
        .frame(height: expanded ? size.height : Self.miniBarHeight)
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
    private func fullContentLayout(metrics: ControlMetrics) -> some View {
        if metrics.landscape {
            fullContentLandscape(metrics: metrics)
        } else {
            fullContentPortrait(metrics: metrics)
        }
    }

    @ViewBuilder
    private func fullContent(size: CGSize, landscape: Bool) -> some View {
        let metrics = ControlMetrics(width: size.width, landscape: landscape)
        fullContentLayout(metrics: metrics)
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
        // Match the toolkit player (AudiobookPlayerView ~L118): the full player
        // commits to a dark visual design so the `Color.white.opacity(0.10)` chips
        // and white-opacity foreground read correctly. Applied ONLY to the full
        // content — the mini bar (rendered when minimized) keeps the app scheme.
        .preferredColorScheme(.dark)
    }

    private func fullContentPortrait(metrics: ControlMetrics) -> some View {
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

            transportRow(metrics: metrics)
                .padding(.top, 8)

            bottomControls(metrics: metrics)
                .padding(.top, 22)
                .padding(.bottom, bottomSafeInset + 16)
        }
        .frame(maxWidth: .infinity)
    }

    /// iPhone-landscape branch: cover on the left, title/controls on the right,
    /// bottom-control panel spanning underneath (mirrors toolkit `landscapeLayout`).
    private func fullContentLandscape(metrics: ControlMetrics) -> some View {
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
                    transportRow(metrics: metrics)
                }
                .frame(maxWidth: .infinity)
                .padding(.trailing, 20)
            }
            .padding(.top, 4)

            bottomControls(metrics: metrics)
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

    /// Scrubbable seek bar built on the ported `PalaceSeekSliderView`. The
    /// slider owns its drag state internally (thumb-grow + finger tracking);
    /// while idle it displays live playback progress, and on release it seeks
    /// via `audiobookSession.seek(to:)` (toolkit `seekWithSlider`).
    private var seekBar: some View {
        VStack(spacing: 4) {
            // The ported toolkit scrubber (`PalaceSeekSliderView`): thumb-grow +
            // track-grow on touch, continuous drag-to-seek. `value` reflects
            // playback when idle (display-only fallback) and tracks the finger
            // while dragging; the seek commits via `onChange` on release.
            PalaceSeekSliderView(
                value: Binding(
                    // CHAPTER-relative — the scrubber is chapter-scoped to match
                    // `seekWithSlider`, which seeks `chapterStart + value *
                    // chapterDuration`. Reading the book-relative `playbackProgress`
                    // here made the thumb sit at book-% while the seek treated the
                    // drop as chapter-%, so the playhead jumped and the thumb never
                    // settled. The `set` is a no-op: the seek commits via `onChange`
                    // and the visual hold lives inside the slider — writing here
                    // would corrupt the book-relative progress the "N min remaining"
                    // text depends on.
                    get: { chapterProgressClamped },
                    set: { _ in }
                ),
                onChange: { audiobookSession.seek(to: $0) }
            )
            .accessibilityLabel(Strings.Generic.playbackPosition)
            .accessibilityValue(seekAccessibilityValue)
            // Row under the bar: chapter elapsed · chapter name · chapter time-left
            // (mirrors toolkit `playheadOffsetText` / `chapterTitle` / `timeLeftText`).
            // The title is centered in the FULL row width via a ZStack so it stays
            // fixed as the flanking timecodes change character-width (even
            // monospaced, "9:59" → "10:00" adds a digit). The times pin to the
            // edges; the title (subheadline) defines the row height as before, and
            // its horizontal padding keeps it clear of the times.
            ZStack {
                Text(audiobookSession.currentChapter?.title ?? presenter.currentBook?.title ?? "")
                    .font(.subheadline).fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 64)
                HStack(spacing: 8) {
                    Text(chapterElapsedString)
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityLabel(Strings.Generic.timeElapsedLabel(chapterElapsedString))
                    Spacer(minLength: 8)
                    Text(chapterRemainingString)
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityLabel(Strings.Generic.timeRemainingLabel(chapterRemainingString))
                }
            }
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
                    .monospacedDigit()
                    .padding(.top, 2)
            }
        }
    }

    /// Transport row, mirroring the toolkit `playbackControlsView`
    /// (`AudiobookPlayerView.swift` ~L471-491): skip-back · play/pause · skip-
    /// forward on an `HStack(spacing: 40)` (landscape 25), fixed `.frame(height: 72)`
    /// (landscape 56). The play button matches the toolkit `playButton` — a
    /// `Color.white.opacity(0.12)` circle with a white glyph (correct on the
    /// forced-dark canvas).
    private func transportRow(metrics: ControlMetrics) -> some View {
        HStack(spacing: metrics.transportSpacing) {
            transportButton("gobackward.30", label: Strings.Generic.skipBack30, size: metrics.skipGlyph) {
                audiobookSession.skipBack()
            }
            Button(action: { audiobookSession.togglePlayPause() }) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.12))
                    Image(systemName: presenter.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: metrics.playGlyph))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: metrics.playButton, height: metrics.playButton)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presenter.isPlaying ? Strings.Generic.pauseAudiobook : Strings.Generic.playAudiobook)
            transportButton("goforward.30", label: Strings.Generic.skipForward30, size: metrics.skipGlyph) {
                audiobookSession.skipForward()
            }
        }
        .frame(height: metrics.transportHeight)
    }

    /// Bottom control row, mirroring the toolkit `controlPanelView`
    /// (`AudiobookPlayerView.swift` ~L498-596): four capsule chips — SPEED ·
    /// AirPlay · SLEEP · BOOKMARK — on an `HStack(spacing: chipSpacing)` with a
    /// `Spacer(minLength: 0)` BETWEEN EACH (even distribution). Adaptive sizing
    /// (`chipHeight`/`fontSize`/`iconSize`/`chipPadH`/`outerPadH`/`chipSpacing`)
    /// comes straight from the toolkit. Chips use `Color.white.opacity(0.10)` on
    /// the forced-dark canvas with `.foregroundColor(.white.opacity(0.9))`.
    private func bottomControls(metrics: ControlMetrics) -> some View {
        let chipBg = Color.white.opacity(0.10)

        return HStack(spacing: metrics.chipSpacing) {
            // Speed → opens the stepped speed sheet.
            Button { showSpeedSheet = true } label: {
                Text(currentRate.displayLabel)
                    .font(.system(size: metrics.fontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, metrics.chipPadH + 2)
                    .frame(height: metrics.chipHeight)
                    .background(chipBg)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.Generic.playbackSpeedValue(currentRate.displayLabel))

            Spacer(minLength: 0)

            // AirPlay route picker.
            AirPlayRoutePicker()
                .frame(width: 30, height: 30)
                .frame(height: metrics.chipHeight)
                .padding(.horizontal, metrics.chipPadH)
                .background(chipBg)
                .clipShape(Capsule())
                .accessibilityLabel(Strings.Generic.airplay)

            Spacer(minLength: 0)

            // Sleep timer → moon.fill + countdown when active.
            Menu {
                ForEach(SleepTimerTriggerAt.allCases, id: \.self) { trigger in
                    Button(trigger.displayTitle) {
                        audiobookSession.setSleepTimer(trigger)
                    }
                }
            } label: {
                HStack(spacing: metrics.narrow ? 4 : 6) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: metrics.iconSize - 2))
                    if audiobookSession.sleepTimerIsActive {
                        Text(AudiobookMiniPlayerView.formatTime(audiobookSession.sleepTimerRemaining))
                            .font(.system(size: metrics.fontSize - 1, weight: .medium, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                .padding(.horizontal, metrics.chipPadH)
                .frame(height: metrics.chipHeight)
                .background(chipBg)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .accessibilityLabel(Strings.Generic.sleepTimer)

            Spacer(minLength: 0)

            // Bookmark ADDS a bookmark (TOC/list stays reachable via the
            // top-trailing list button).
            Button { addBookmarkFromControl() } label: {
                Image(systemName: "bookmark")
                    .font(.system(size: metrics.iconSize))
                    .padding(.horizontal, metrics.chipPadH)
                    .frame(height: metrics.chipHeight)
                    .background(chipBg)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.Generic.addBookmark)
        }
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, metrics.outerPadH)
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
                Image(systemName: Self.toastIsError(toastText)
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
        // White glyph to match the toolkit skip controls (`.foregroundColor(.primary)`
        // on the forced-dark canvas).
        .tint(.white)
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

    /// Pull DOWN on the full player to minimize — now INTERACTIVE: the card
    /// tracks the finger during the drag (revealing the tab content behind it)
    /// and, on release, either animates to minimized (past threshold OR flung
    /// down with enough predicted velocity) or springs back to expanded.
    /// Upward drags are rubber-banded (resisted + clamped). The gesture lives
    /// only on the grabber + cover, so the transport/seek/bottom controls keep
    /// their own taps (the Phase-2 gesture fixes).
    private var minimizeDrag: some Gesture {
        // GLOBAL coordinate space, not local: this gesture lives on the cover,
        // which is INSIDE the card that `cardOffsetY` moves by `dragTranslation`.
        // In `.local`, each translation sample is measured against a frame that is
        // itself being pushed down by the offset we just applied — a feedback loop
        // that oscillates the card (the "jittery pull-down"). A fixed screen frame
        // makes `translation.height` the true finger delta, so the offset tracks
        // the finger 1:1 with no self-interference.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                // Ignore predominantly-horizontal drags so a sideways swipe
                // over the cover doesn't drag the card.
                guard abs(value.translation.width) < abs(value.translation.height) else { return }
                let h = value.translation.height
                dragTranslation = h >= 0 ? h : Self.rubberBand(h)
            }
            .onEnded { value in
                let horizontalOK = abs(value.translation.width) < 80
                let pastThreshold = value.translation.height > 80
                let flungDown = value.predictedEndTranslation.height > 200
                settleDrag(minimize: horizontalOK && (pastThreshold || flungDown))
            }
    }

    /// Resistance curve for an upward (negative) pull on the full player: the
    /// card can only go DOWN to minimize, so an upward drag is rubber-banded. Uses
    /// the iOS scroll-bounce formula `(1 - 1/(x/d + 1)) · limit` — natural
    /// diminishing resistance that asymptotes toward `-limit` instead of the old
    /// hard linear clamp, so the top edge feels elastic rather than stuck. Static +
    /// pure so it's unit-testable. `offset` is expected ≤ 0 (an upward drag).
    static func rubberBand(_ offset: CGFloat) -> CGFloat {
        guard offset < 0 else { return offset }
        let limit: CGFloat = 72
        let dim: CGFloat = 200
        let magnitude = -offset
        return -(1 - 1 / (magnitude / dim + 1)) * limit
    }

    /// Finishes an interactive pull-down: on `minimize == true` animate the
    /// morph to the mini bar; otherwise spring the card back to expanded. Both
    /// reset `dragTranslation` to 0 inside the SAME animation transaction so the
    /// offset and the morph move together (no jump). Reduce-motion → no animation.
    private func settleDrag(minimize shouldMinimize: Bool) {
        let apply = {
            if shouldMinimize { presenter.minimize() }
            dragTranslation = 0
        }
        if UIAccessibility.isReduceMotionEnabled {
            apply()
        } else {
            // Minimize rides the player-morph spring so the offset return and the
            // cover matchedGeometry settle on ONE coherent curve. A spring-back
            // (released below threshold) uses the interruptible interactive spring
            // so re-grabbing the card mid-settle blends cleanly.
            withAnimation(shouldMinimize ? PalaceMotion.playerMorph : PalaceMotion.interactive) {
                apply()
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

    private func setExpanded(_ value: Bool) {
        if UIAccessibility.isReduceMotionEnabled {
            value ? presenter.expand() : presenter.minimize()
        } else {
            withAnimation(PalaceMotion.playerMorph) {
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
                if let error {
                    presentToast(Self.bookmarkErrorMessage(for: error))
                } else {
                    presentToast(Strings.Generic.bookmarkAdded)
                }
            }
        }
    }

    /// Maps a bookmark-add failure to an app-side localized toast string. The
    /// toolkit's `BookmarkError` is public but its `localizedDescription` is
    /// module-internal (unreachable here), so the raw `Error.localizedDescription`
    /// would surface the useless "operation couldn't be completed" text. Match
    /// the two known cases to faithful app-side copy; anything else falls back to
    /// the generic add-failed string. Static + pure so it's unit-testable.
    static func bookmarkErrorMessage(for error: Error) -> String {
        switch error {
        case BookmarkError.bookmarkAlreadyExists:
            return Strings.Generic.bookmarkAlreadyExists
        case BookmarkError.bookmarkFailedToSave:
            return Strings.Generic.bookmarkFailedToSave
        default:
            return Strings.Generic.bookmarkAddFailed
        }
    }

    /// Whether a toast string represents a failure (error icon) vs. a success
    /// (bookmark icon). Success is only the bookmark-added string; every failure
    /// copy — the generic add-failed plus the two mapped `BookmarkError` cases —
    /// shows the error glyph. Static + pure so it's unit-testable.
    static func toastIsError(_ text: String) -> Bool {
        text != Strings.Generic.bookmarkAdded
            && (text.localizedCaseInsensitiveContains("error")
                || text == Strings.Generic.bookmarkAddFailed
                || text == Strings.Generic.bookmarkAlreadyExists
                || text == Strings.Generic.bookmarkFailedToSave)
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

    /// Book-relative progress (0…1 across the whole book) — drives the mini
    /// player's overall progress bar. NOT the scrubber (see `chapterProgressClamped`).
    private var clampedProgress: Double {
        progress.playbackProgress.isFinite ? min(max(progress.playbackProgress, 0), 1) : 0
    }

    /// Chapter-relative progress (0…1 within the current chapter) — drives the
    /// seek scrubber so its thumb position matches `seekWithSlider`'s chapter scale.
    private var chapterProgressClamped: Double {
        progress.chapterProgress.isFinite ? min(max(progress.chapterProgress, 0), 1) : 0
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

    /// Spoken value for the seek slider: percent through the current chapter
    /// (the scrubber is chapter-scoped) plus the chapter elapsed timecode.
    private var seekAccessibilityValue: String {
        "\(Int(chapterProgressClamped * 100))%, \(chapterElapsedString)"
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
        // Book-relative remaining straight from the playhead — NOT derived from a
        // progress fraction. `durationToSelf()` is the book-elapsed time; deriving
        // `total * scrubberFraction` would leap whenever the (chapter-scoped)
        // scrubber moved. This reads the true book position independently.
        let total = position.tracks.totalDuration
        let remaining = max(0, total - position.durationToSelf())
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

// MARK: - PalaceSeekSliderView

/// The audiobook seek scrubber, ported verbatim from the toolkit's
/// `PlaybackSliderView` (`AudiobookPlayerView.swift`): a thin rounded track that
/// grows on touch, with a circular thumb that scales up while dragging. It is
/// ADAPTIVE-colored (`Color(.systemGray4)` track, `Color(.label)` fill + thumb),
/// so it renders correctly in both light and dark appearance.
///
/// Behavior: `value` reflects live playback when idle (display-only fallback);
/// on touch the thumb/track grow (`withAnimation(.easeOut)`), a
/// `DragGesture(minimumDistance: 0)` continuously tracks the finger via a
/// `tempValue`, and on release the position is committed once through `onChange`
/// (plus a light seek-commit haptic). The caller supplies `accessibilityLabel`
/// / `accessibilityValue` at the call site.
@MainActor
struct PalaceSeekSliderView: View {
    @Binding var value: Double
    var onChange: (_ value: Double) -> Void

    @State private var tempValue: Double?
    @State private var isDragging: Bool = false
    @State private var isCommitting: Bool = false

    private let trackRest: CGFloat = 4
    private let trackActive: CGFloat = 6
    private let thumbRest: CGFloat = 8
    private let thumbActive: CGFloat = 14
    private let hitHeight: CGFloat = 44

    private var currentTrackHeight: CGFloat { isDragging ? trackActive : trackRest }
    private var currentThumbSize: CGFloat { isDragging ? thumbActive : thumbRest }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color(.systemGray4))
                    .frame(height: currentTrackHeight)

                // Progress fill
                Capsule()
                    .fill(Color(.label))
                    .frame(
                        width: max(currentTrackHeight, progressWidth(in: width)),
                        height: currentTrackHeight
                    )

                // Thumb
                Circle()
                    .fill(Color(.label))
                    .frame(width: currentThumbSize, height: currentThumbSize)
                    .offset(x: thumbOffset(in: width))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            withAnimation(.easeOut(duration: 0.15)) { isDragging = true }
                        }
                        let newValue = max(0, min(1, Double(gesture.location.x / width)))
                        tempValue = newValue
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.2)) { isDragging = false }
                        if let finalValue = tempValue {
                            isCommitting = true
                            value = finalValue
                            // Subtle completion haptic on seek commit (toolkit parity).
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onChange(finalValue)
                            // HOLD the committed thumb position until the LIVE
                            // playback value converges to the seek target (see
                            // `.onChange(of: value)` below). Unlike the toolkit —
                            // whose binding is not a high-frequency player mirror —
                            // our `value` reads `progress.playbackProgress`, which
                            // the player republishes every tick. A fixed 0.1s clear
                            // let a STALE pre-seek tick overwrite the optimistic
                            // `value = finalValue` before the async seek landed, so
                            // the thumb snapped back to the old position while time
                            // moved forward. We instead keep `tempValue` until the
                            // seek propagates, with a safety timeout so a failed /
                            // silent seek can never wedge the thumb.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                if isCommitting {
                                    tempValue = nil
                                    isCommitting = false
                                }
                            }
                        }
                    }
            )
            // Release the committed-position hold once live playback progress
            // has caught up to the seek target (the async seek has landed and
            // the player is now republishing from the new position). Guarded on
            // `isCommitting` so idle ticks never touch `tempValue`.
            .onChange(of: value) { newValue in
                guard isCommitting, let target = tempValue else { return }
                if abs(newValue - target) <= 0.01 {
                    tempValue = nil
                    isCommitting = false
                }
            }
        }
        .frame(height: hitHeight)
    }

    private var displayValue: Double {
        tempValue ?? value
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        CGFloat(displayValue) * totalWidth
    }

    private func thumbOffset(in totalWidth: CGFloat) -> CGFloat {
        CGFloat(displayValue) * (totalWidth - currentThumbSize)
    }
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
