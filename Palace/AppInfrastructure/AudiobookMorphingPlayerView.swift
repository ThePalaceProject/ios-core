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

    /// Current playback-rate label (e.g. "1.0×"), refreshed when the chip cycles.
    @State private var rateLabel: String = ""

    /// Presents the toolkit's Chapters + Bookmarks list (`AudiobookNavigationView`).
    @State private var showChaptersBookmarks = false

    /// Live scrubber position + whether the user is dragging it. While dragging,
    /// the bar tracks the finger (not playback); on release it seeks.
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

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

            card(expanded: expanded, screenHeight: geo.size.height)
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
    private func card(expanded: Bool, screenHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Color(.systemBackground)
            if expanded {
                fullContent
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

    private var fullContent: some View {
        VStack(spacing: 0) {
            topControls

            titleAuthorFull
                .padding(.top, 8)
                .padding(.horizontal, 24)

            seekBar
                .padding(.horizontal, 24)
                .padding(.top, 14)

            chapterLabel
                .padding(.top, 6)

            Spacer(minLength: 16)

            coverImageOrPlaceholder
                .frame(maxWidth: 320)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .matchedGeometryEffect(id: Self.coverMatchID, in: morphNamespace)
                .padding(.horizontal, 40)
                // Pull the cover DOWN to minimize (a large, safe drag zone).
                .contentShape(Rectangle())
                .gesture(minimizeDrag)

            Spacer(minLength: 16)

            transportRow
                .padding(.top, 8)

            bottomControls
                .padding(.top, 22)
                .padding(.bottom, bottomSafeInset + 16)
        }
        .frame(maxWidth: .infinity)
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
        .accessibilityElement(children: .contain)
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

    private var chapterLabel: some View {
        Text(audiobookSession.currentChapter?.title ?? presenter.currentBook?.title ?? "")
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 24)
            .accessibilityHidden(true)
    }

    /// Scrubbable seek bar. While the user drags, `scrubValue` tracks the finger
    /// and playback ticks are ignored; on release it seeks via
    /// `audiobookSession.seek(to:)` (toolkit `seekWithSlider`).
    private var seekBar: some View {
        VStack(spacing: 4) {
            Slider(value: $scrubValue, in: 0...1) { editing in
                isScrubbing = editing
                if !editing { audiobookSession.seek(to: scrubValue) }
            }
            .tint(.accentColor)
            HStack {
                Text(elapsedString).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(remainingString).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { scrubValue = clampedProgress }
        .onChange(of: clampedProgress) { _, newValue in
            if !isScrubbing { scrubValue = newValue }
        }
        .accessibilityLabel("Seek")
    }

    private var titleAuthorFull: some View {
        VStack(spacing: 4) {
            Text(presenter.currentBook?.title ?? "")
                .font(.title3).fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
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
                Image(systemName: presenter.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .tint(.accentColor)
            .accessibilityLabel(presenter.isPlaying ? Strings.Generic.pauseAudiobook : Strings.Generic.playAudiobook)
            transportButton("goforward.30", label: Strings.Generic.skipForward30, size: 32) {
                audiobookSession.skipForward()
            }
        }
    }

    /// Bottom control row, mirroring the original player: playback-speed chip,
    /// AirPlay route picker, and a Bookmarks button (opens the same
    /// Chapters/Bookmarks list). (Sleep timer needs a public toolkit hook — a
    /// follow-up like `seek(to:)` — so it is deferred.)
    private var bottomControls: some View {
        HStack(spacing: 0) {
            Button(action: cycleRate) {
                Text(rateLabel.isEmpty ? currentRateLabel : rateLabel)
                    .font(.subheadline).fontWeight(.medium)
                    .frame(minWidth: 52)
                    .padding(.vertical, 6).padding(.horizontal, 12)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed")

            Spacer()

            AirPlayRoutePicker()
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")

            Button { showChaptersBookmarks = true } label: {
                Image(systemName: "bookmark")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .accessibilityLabel("Bookmarks")
        }
        .padding(.horizontal, 28)
    }

    private func transportButton(_ system: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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

    private func cycleRate() {
        let newRate = audiobookSession.cyclePlaybackRate()
        rateLabel = Self.label(for: newRate)
    }

    // MARK: - Derived

    private var clampedProgress: Double {
        progress.playbackProgress.isFinite ? min(max(progress.playbackProgress, 0), 1) : 0
    }

    private var elapsedString: String {
        guard let position = progress.currentLocation else { return "--:--" }
        return AudiobookMiniPlayerView.formatTime(position.durationToSelf())
    }

    private var remainingString: String {
        guard let position = progress.currentLocation else { return "--:--" }
        let remaining = position.tracks.totalDuration - position.durationToSelf()
        return "-" + AudiobookMiniPlayerView.formatTime(max(0, remaining))
    }

    private var currentRateLabel: String {
        // Best-effort initial label; the chip updates it on first cycle.
        "1.0×"
    }

    static func label(for rate: PlaybackRate) -> String {
        let value = Double(PlaybackRate.convert(rate: rate))
        // Trim trailing zero on whole/half values → "1×", "1.5×", "0.75×".
        let str = String(format: "%g", value)
        return str + "×"
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
