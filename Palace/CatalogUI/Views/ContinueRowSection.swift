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

// MARK: - ContinueRowSection

@MainActor
struct ContinueRowSection: View {
    @ObservedObject var viewModel: ActiveSessionsViewModel
    let onResumeReading: (TPPBook) -> Void
    let onResumeListening: (TPPBook) -> Void

    /// Collapsible state. Defaults to OPEN on first launch (per user
    /// feedback after the initial collapsed default — "should default
    /// to open on first launch"). Persisted across launches via
    /// `@AppStorage` so a user who collapses it sees it stay collapsed
    /// next launch; a user who hasn't touched it gets the default
    /// open experience.
    @AppStorage("ContinueRowSection.isExpanded") private var isExpanded: Bool = true

    var body: some View {
        if let item = viewModel.mostRecent {
            VStack(alignment: .leading, spacing: 0) {
                // Collapsible header
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }, label: {
                    HStack {
                        Text(Strings.CatalogContinueRows.continueHeader)
                            .font(.title2)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded
                    ? Strings.CatalogContinueRows.collapseHint
                    : Strings.CatalogContinueRows.expandHint)

                // Single-item body (user feedback: "only show the last book,
                // not the last ebook or audiobook"). Active audiobook always
                // wins; reading falls back when no listening session active.
                if isExpanded {
                    ContinueSingleItemRow(
                        item: item,
                        onTap: { book in
                            switch item {
                            case .listening: onResumeListening(book)
                            case .reading:   onResumeReading(book)
                            }
                        }
                    )
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
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
        Button(action: { onTap(item.book) }, label: {
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
