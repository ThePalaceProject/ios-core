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

    var body: some View {
        if viewModel.continueListening.isEmpty && viewModel.continueReading.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                // §11 row 4 — Audible pattern. Listening first when present.
                if !viewModel.continueListening.isEmpty {
                    ContinueListeningRow(
                        items: viewModel.continueListening,
                        onTap: onResumeListening
                    )
                }
                if !viewModel.continueReading.isEmpty {
                    ContinueReadingRow(
                        items: viewModel.continueReading,
                        onTap: onResumeReading
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - ContinueListeningRow

private struct ContinueListeningRow: View {
    let items: [ContinueListeningItem]
    let onTap: (TPPBook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.CatalogContinueRows.continueListeningTitle)
                .font(.title2)
                .padding(.horizontal, 12)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        Button(action: { onTap(item.book) }, label: {
                            ContinueListeningCard(item: item)
                        })
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                        .accessibilityLabel(accessibilityLabel(for: item))
                        .accessibilityHint(Strings.CatalogContinueRows.continueListeningHint)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    /// "<Title>, audiobook, by <Author>, currently playing" — Audible-style
    /// label. Falls back gracefully when author is missing.
    private func accessibilityLabel(for item: ContinueListeningItem) -> String {
        var parts: [String] = [item.book.title, Strings.Generic.audiobook]
        if let authors = item.book.authors, !authors.isEmpty {
            parts.append(Strings.CatalogContinueRows.byAuthor(authors))
        }
        if item.isCurrentlyPlaying {
            parts.append(Strings.CatalogContinueRows.currentlyPlaying)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - ContinueListeningCard

private struct ContinueListeningCard: View {
    let item: ContinueListeningItem

    var body: some View {
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
                Text(item.book.title)
                    .font(.headline)
                    .lineLimit(2)
                if let authors = item.book.authors, !authors.isEmpty {
                    Text(authors)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let chapter = item.chapterTitle {
                    Text(chapter)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: item.isCurrentlyPlaying ? "pause.fill" : "play.fill")
                        .accessibilityHidden(true)
                    if let label = item.progressLabel {
                        Text(label)
                            .font(.caption)
                    }
                }
                .foregroundColor(.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - ContinueReadingRow

private struct ContinueReadingRow: View {
    let items: [ContinueReadingItem]
    let onTap: (TPPBook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.CatalogContinueRows.continueReadingTitle)
                .font(.title2)
                .padding(.horizontal, 12)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        Button(action: { onTap(item.book) }, label: {
                            ContinueReadingCard(item: item)
                        })
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                        .accessibilityLabel(accessibilityLabel(for: item))
                        .accessibilityHint(Strings.CatalogContinueRows.continueReadingHint)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func accessibilityLabel(for item: ContinueReadingItem) -> String {
        var parts: [String] = [item.book.title]
        if let authors = item.book.authors, !authors.isEmpty {
            parts.append(Strings.CatalogContinueRows.byAuthor(authors))
        }
        if let label = item.progressLabel {
            parts.append(label)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - ContinueReadingCard

private struct ContinueReadingCard: View {
    let item: ContinueReadingItem

    var body: some View {
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
                Text(item.book.title)
                    .font(.headline)
                    .lineLimit(2)
                if let authors = item.book.authors, !authors.isEmpty {
                    Text(authors)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let label = item.progressLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let fraction = item.progressFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
