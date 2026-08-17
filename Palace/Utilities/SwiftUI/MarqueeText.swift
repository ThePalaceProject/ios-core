//
//  MarqueeText.swift
//  Palace
//
//  A single line of text that marquee-scrolls horizontally when it is too wide
//  for the space it is given, and sits still (truncating with an ellipsis) when
//  it fits. Built for the revised audiobook mini-player (PP-4910), where the
//  title and author must remain fully readable in a narrow bar.
//
//  Accessibility: the scroll is a continuous, decorative animation, so it is
//  suppressed under Reduce Motion — the text then simply truncates. The whole
//  view is one VoiceOver element labelled with the full (un-truncated) string,
//  so a blind patron always hears the complete title/author regardless of the
//  visible truncation.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary

    /// Gap between the trailing edge of the first copy and the leading edge of
    /// the second so the wrap reads as a continuous crawl rather than a snap.
    private let gap: CGFloat = 44
    /// Scroll speed in points per second — a calm, readable crawl.
    private let pointsPerSecond: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    /// Flipped true (once) to launch the perpetual crawl. Bound to
    /// `.animation(_:value:)` so the repeat-forever motion is DECLARATIVE — it
    /// survives the mini player's frequent re-renders, unlike an imperative
    /// `withAnimation` which those re-renders cancelled (the "stop").
    @State private var animate = false

    /// Pure gate: scroll only when the text STRICTLY overflows a measured
    /// container AND Reduce Motion is off. Factored out so the decision — the
    /// mutation-testable heart of the marquee — is assertable without a SwiftUI
    /// host. A `0` container width means "not yet laid out": never scroll.
    nonisolated static func shouldScroll(textWidth: CGFloat, containerWidth: CGFloat, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        guard containerWidth > 0 else { return false }
        return textWidth > containerWidth
    }

    private var scrolling: Bool {
        Self.shouldScroll(textWidth: textWidth, containerWidth: containerWidth, reduceMotion: reduceMotion)
    }

    /// One period of travel: the first copy's width plus the trailing gap. When
    /// the pair has shifted left by exactly this, the second copy sits where the
    /// first began — so looping this translation reads as one continuous crawl.
    private var period: CGFloat { textWidth + gap }

    /// The perpetual right-to-left crawl: linear (constant speed), no
    /// autoreverse (always leftward), repeating forever. `nil` when not
    /// scrolling so the offset snaps back without motion.
    private var crawl: Animation? {
        guard scrolling, period > 0 else { return nil }
        return .linear(duration: Double(period / pointsPerSecond)).repeatForever(autoreverses: false)
    }

    /// The intrinsic-width copy used both for the scrolling pair and (hidden) for
    /// measuring the text's natural width.
    private func line() -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        // BASE: a single truncated line. It defines the row height and claims
        // exactly the flexible width the bar hands us — NEVER the 2×text
        // intrinsic width — so the marquee can't crowd its sibling controls
        // (the rewind/play/forward transport) off the bar. When scrolling, the
        // base goes transparent and the moving two-copy pair rides as an
        // OVERLAY; overlays don't feed their size back to the primary, so the
        // scroll stays clipped to THIS slot instead of spanning the whole bar.
        Text(text)
            .font(font)
            .foregroundStyle(scrolling ? Color.clear : color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                // The moving pair is ALWAYS in the tree (visibility gated by
                // opacity) so the repeating animation attaches to a stable view.
                // Its offset is DECLARATIVELY bound via `.animation(crawl, value:
                // animate)`: flipping `animate` once starts a linear repeat-
                // forever translation of one `period` left, which loops as a
                // continuous crawl. Two copies one period apart make the wrap
                // seamless (no flash). As an overlay it can't feed its 2×text
                // intrinsic width back into the row.
                HStack(spacing: gap) {
                    line()
                    line()
                }
                .fixedSize()
                .offset(x: animate ? -period : 0)
                .opacity(scrolling ? 1 : 0)
                .animation(crawl, value: animate)
                .allowsHitTesting(false)
            }
            .clipped()
            // Measure the LAID-OUT width (the slot the bar gives us).
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ContainerWidthKey.self, value: proxy.size.width)
                }
            )
            // Measure the text's NATURAL width with a hidden, layout-neutral copy
            // (an overlay does not feed its child's size back to the primary, so
            // this never expands the bar).
            .overlay(alignment: .leading) {
                line()
                    .hidden()
                    .allowsHitTesting(false)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: TextWidthKey.self, value: proxy.size.width)
                        }
                    )
            }
            .onPreferenceChange(ContainerWidthKey.self) { containerWidth = $0 }
            .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
            .onChange(of: scrolling) { _, now in restartCrawl(shouldScroll: now) }
            .onAppear { restartCrawl(shouldScroll: scrolling) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    /// (Re)launch the crawl from the leading edge. Reset `animate` to false, then
    /// flip it true on the NEXT runloop so `0 -> true` is a distinct transition
    /// the value-bound animation applies (a same-tick reset+set can coalesce and
    /// never animate). When not scrolling, just park at the leading edge.
    private func restartCrawl(shouldScroll: Bool) {
        animate = false
        guard shouldScroll else { return }
        Task { @MainActor in animate = true }
    }
}

/// The laid-out width of the marquee's slot.
private struct ContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The text's natural (un-truncated) width.
private struct TextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
