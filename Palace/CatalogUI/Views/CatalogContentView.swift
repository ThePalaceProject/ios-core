import SwiftUI
import PalaceBookModel
import PalaceBookRegistry

// MARK: - CatalogContentView (Data-Driven)

struct CatalogContentView: View {
    let content: CatalogContent
    let isOptimisticLoading: Bool
    let scrollGeneration: UInt
    let onBookSelected: (TPPBook) -> Void
    let onLaneMoreTapped: (String, URL) -> Void
    let onEntryPointSelected: (CatalogFilter) -> Void
    let onFacetSelected: (CatalogFilter) -> Void
    let onRefresh: () async -> Void
    var bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The "Continue" section (Continue Reading / Continue Listening hero
            // rows) was removed in PP-4910: with the in-app mini-player it was a
            // redundant re-entry point. If a re-entry point is wanted later it
            // should be designed on its own. The `continuation_cards_enabled`
            // flag is intentionally left in place (out of scope for PP-4910).
            selectorsView

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        SwiftUI.Group {
                            feedContentView
                                .padding(.vertical, 17)
                                .id("catalog-content-top")
                                .accessibleAnimation(PalaceMotion.standard, value: feedIsEmpty)
                        }
                    }
                    .padding(.vertical, 17)
                }
                .refreshable { await onRefresh() }
                .onChange(of: scrollGeneration) { _, _ in
                    accessibleWithAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("catalog-content-top", anchor: .top)
                    }
                }
            }
        }
    }
}

// MARK: - Subviews

private extension CatalogContentView {
    @ViewBuilder
    var selectorsView: some View {
        if !content.selectors.entryPoints.isEmpty {
            EntryPointsSelectorView(entryPoints: content.selectors.entryPoints) { facet in
                onEntryPointSelected(facet)
            }
        }

        if !content.selectors.facetGroups.isEmpty {
            FacetsSelectorView(facetGroups: content.selectors.facetGroups) { facet in
                onFacetSelected(facet)
            }
        }
    }

    @ViewBuilder
    var feedContentView: some View {
        switch content.feed {
        case .grouped(let lanes):
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(Array(lanes.enumerated()), id: \.element.id) { idx, lane in
                    CatalogLaneRowView(
                        title: lane.title,
                        // Read-only: updatedBookMetadata writes + disk-saves on the main thread (froze render).
                        books: lane.books.map { bookRegistry.book(forIdentifier: $0.identifier) ?? $0 },
                        moreURL: lane.moreURL,
                        onSelect: onBookSelected,
                        onMoreTapped: onLaneMoreTapped,
                        showHeader: true,
                        isLoading: lane.isLoading || isOptimisticLoading
                    )
                    .onAppear {
                        // When a lane scrolls into view, warm the first few covers of
                        // the next lane so its cells don't have to wait on the network
                        // when the user scrolls further. fetchCoverImage is a no-op if
                        // the image is already cached (or in flight), so repeat calls
                        // are safe and cheap.
                        guard idx + 1 < lanes.count else { return }
                        let nextLane = lanes[idx + 1]
                        for book in nextLane.books.prefix(3) {
                            book.fetchCoverImage(forDisplayHeight: 150)
                        }
                    }
                }
            }
            .opacity(isOptimisticLoading ? 0.6 : 1.0)
            .accessibleAnimation(.easeInOut(duration: 0.2), value: isOptimisticLoading)

        case .ungrouped(let books):
            BookListView(
                books: books,
                isLoading: .constant(isOptimisticLoading),
                onSelect: onBookSelected
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Strings.Generic.booksListLabel)
            .accessibilityValue(Strings.SearchAnnouncements.searchResultsListValue(bookCount: books.count))
            .accessibilityHint(Strings.SearchAnnouncements.searchResultsListHint)
            .opacity(isOptimisticLoading ? 0.6 : 1.0)
            .accessibleAnimation(.easeInOut(duration: 0.2), value: isOptimisticLoading)

        case .empty:
            ContentUnavailableView {
                Label(Strings.Catalog.emptyFeedTitle, systemImage: "books.vertical")
            } description: {
                Text(Strings.Catalog.emptyFeedMessage)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .transition(.opacity)
        }
    }

    /// Whether the current feed renders no books (drives the empty-state
    /// cross-fade animation below).
    var feedIsEmpty: Bool {
        if case .empty = content.feed { return true }
        return false
    }
}

// MARK: - Switching Entry Point View

extension CatalogContentView {
    /// Skeleton placeholder shown while an entry point feed loads.
    /// Entry point tabs remain visible above the skeleton.
    static func switchingEntryPointView(
        selectors: CatalogSelectors,
        onEntryPointSelected: @escaping (CatalogFilter) -> Void,
        onRefresh: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !selectors.entryPoints.isEmpty {
                EntryPointsSelectorView(entryPoints: selectors.entryPoints) { facet in
                    onEntryPointSelected(facet)
                }
            }
            ScrollView {
                CatalogLoadingView()
            }
            .refreshable { await onRefresh() }
        }
    }
}

// MARK: - CatalogLoadingView

struct CatalogLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(0..<3, id: \.self) { _ in
                CatalogLaneSkeletonView()
            }
        }
        .padding(.vertical, 17)
    }
}
