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
        .contentShape(Rectangle())
    }

    // MARK: - Full layout

    private var fullContent: some View {
        VStack(spacing: 0) {
            grabber
                .padding(.top, topSafeInset + 4)

            chapterLabel
                .padding(.top, 4)

            fullScrubber
                .padding(.horizontal, 24)
                .padding(.top, 8)

            Spacer(minLength: 12)

            coverImageOrPlaceholder
                .frame(maxWidth: 320)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .matchedGeometryEffect(id: Self.coverMatchID, in: morphNamespace)
                .padding(.horizontal, 40)

            titleAuthorFull
                .padding(.top, 20)
                .padding(.horizontal, 24)

            Spacer(minLength: 12)

            transportRow
                .padding(.top, 8)

            secondaryRow
                .padding(.top, 20)
                .padding(.bottom, bottomSafeInset + 16)
        }
        .frame(maxWidth: .infinity)
        // Pull DOWN anywhere on the full player to minimize (the detent feel);
        // there is no prominent dismiss up here — Stop lives as a small control.
        .contentShape(Rectangle())
        .gesture(minimizeDrag)
        .accessibilityElement(children: .contain)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 40, height: 5)
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

    private var fullScrubber: some View {
        VStack(spacing: 4) {
            ProgressView(value: clampedProgress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(.accentColor)
            HStack {
                Text(elapsedString).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(remainingString).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
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

    private var secondaryRow: some View {
        HStack {
            // Playback-rate chip
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

            // Small, secondary Stop — de-emphasized vs. pull-down-to-minimize.
            Button(action: stop) {
                Text(Strings.Generic.stopAudiobook)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.Generic.stopAudiobook)
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

                Spacer(minLength: 4)

                Button(action: { audiobookSession.togglePlayPause() }) {
                    Image(systemName: presenter.isPlaying ? "pause.fill" : "play.fill")
                        .resizable().aspectRatio(contentMode: .fit)
                        .padding(12).frame(width: 44, height: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain).tint(.accentColor)
                .accessibilityLabel(presenter.isPlaying ? Strings.Generic.pauseAudiobook : Strings.Generic.playAudiobook)

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
}
