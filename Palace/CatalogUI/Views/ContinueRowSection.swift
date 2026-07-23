//
//  ContinueRowSection.swift
//  Palace
//
//  Renders the "Continue Listening" + "Continue Reading" hero rows that
//  sit at the top of the Catalog feed. Driven by Module A's
//  `ActiveSessionsViewModel` (`continueReading` / `continueListening`);
//  tap handlers are injected closures so this view is independent of
//  `AppContainer` and trivially unit-testable.
//
//  Empty-row policy (§11 row decisions in
//  `docs/architecture/in-app-navigation-during-playback.md`):
//    - When `viewModel.continueListening` is empty, the listening row is
//      not rendered at all (no placeholder).
//    - When `viewModel.continueReading` is empty, the reading row is not
//      rendered at all.
//    - When BOTH are empty, the view returns `EmptyView` so the Catalog
//      feed's existing top of feed is unchanged.
//
//  Row order is Audible-pattern (§11 row 4): Continue Listening first,
//  Continue Reading second.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceBookModel

// MARK: - ContinueRowSection

@MainActor
struct ContinueRowSection: View {
    @ObservedObject var viewModel: ActiveSessionsViewModel
    let onResumeReading: (TPPBook) -> Void
    let onResumeListening: (TPPBook) -> Void

    /// Chevron "pin": `false` = manually pinned collapsed (ignores scroll);
    /// `true` (default) = the scroll-scrub progress drives the collapse.
    @Binding var isExpanded: Bool

    /// Continuous scroll-scrub progress from the host (iOS 18+): 0 = expanded …
    /// 1 = collapsed. Drives the card's height/opacity so it tracks the finger.
    @ObservedObject var collapse: ContinueCollapseModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Natural (uncollapsed) height of the card, measured behind the collapse
    /// clamp so the clamp doesn't feed back into the measurement.
    @State private var cardHeight: CGFloat = 0

    /// Effective collapse progress: chevron-pinned forces fully collapsed (1);
    /// otherwise the scroll scrub drives it. 0 = expanded … 1 = collapsed.
    private var progress: CGFloat { isExpanded ? collapse.progress : 1 }

    var body: some View {
        if let item = viewModel.mostRecent {
            VStack(alignment: .leading, spacing: 0) {
                // Collapsible header
                Button(action: {
                    // Asymmetric feel: collapsing gets out of the way snappily;
                    // expanding settles with the smooth spring. Reduce-Motion-gated.
                    withAnimation(PalaceMotion.resolved(
                        isExpanded ? PalaceMotion.emphasized : PalaceMotion.springy,
                        reduceMotion: reduceMotion
                    )) { isExpanded.toggle() }
                }, label: {
                    HStack {
                        Text(Strings.CatalogContinueRows.continueHeader)
                            .font(.title2)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Image(systemName: progress < 0.5 ? "chevron.up" : "chevron.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                .accessibilityHint(progress < 0.5
                    ? Strings.CatalogContinueRows.collapseHint
                    : Strings.CatalogContinueRows.expandHint)

                // Single most-recent item (user feedback: "only show the last
                // book"). Continuous collapse: the card's height + opacity scrub
                // with the scroll (progress 0→1) so it tracks the finger —
                // collapsing on scroll-in and expanding on scroll-to-top at the
                // scroll's own speed — and slides up under the header. Natural
                // height is measured BEHIND the clamp so the clamp can't feed back.
                ContinueSingleItemRow(
                    item: item,
                    onTap: { book in
                        switch item {
                        case .listening: onResumeListening(book)
                        case .reading:   onResumeReading(book)
                        }
                    }
                )
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { cardHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, newHeight in cardHeight = newHeight }
                    }
                )
                .frame(height: cardHeight > 0 ? cardHeight * (1 - progress) : nil, alignment: .top)
                .opacity(Double(1 - progress))
                .padding(.bottom, 8 * (1 - progress))
                .clipped()
            }
            .clipped()
        } else {
            EmptyView()
        }
    }
}

// MARK: - ContinueSingleItemRow

/// Single most-recent-item row used by the collapsible polish-phase UX.
/// Rendered horizontally like the original audiobook/reading cards but
/// full-width since there's only one item.
private struct ContinueSingleItemRow: View {
    let item: ContinueRowItem
    let onTap: (TPPBook) -> Void

    var body: some View {
        Button(action: {
            // Light tap feedback on resuming from the Continue card. Preference-
            // and Reduce-Motion-gated inside `triggerHaptic`.
            Task { await AccessibilityService.shared.triggerHaptic(.lightImpact) }
            onTap(item.book)
        }, label: {
            HStack(alignment: .top, spacing: 12) {
                BookImageView(
                    book: item.book,
                    width: nil,
                    height: 100,
                    usePulseSkeleton: true,
                    treatImageAsDecorativeInLists: true
                )
                .adaptiveShadow(radius: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !item.author.isEmpty {
                        Text(item.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: typeGlyph)
                            .accessibilityHidden(true)
                        Text(typeLabel)
                            .font(.caption)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var typeGlyph: String {
        switch item {
        case .listening(let l): return l.isCurrentlyPlaying ? "pause.fill" : "play.fill"
        case .reading: return "book.fill"
        }
    }

    private var typeLabel: String {
        switch item {
        case .listening: return Strings.Generic.audiobook
        case .reading: return Strings.Generic.ebook
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = [item.title]
        if !item.author.isEmpty {
            parts.append(Strings.CatalogContinueRows.byAuthor(item.author))
        }
        parts.append(typeLabel)
        return parts.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        switch item {
        case .listening: return Strings.CatalogContinueRows.continueListeningHint
        case .reading: return Strings.CatalogContinueRows.continueReadingHint
        }
    }
}
