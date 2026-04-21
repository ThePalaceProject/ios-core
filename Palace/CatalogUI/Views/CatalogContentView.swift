import SwiftUI

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
    var bookRegistry: TPPBookRegistry = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            selectorsView

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        SwiftUI.Group {
                            feedContentView
                                .padding(.vertical, 17)
                                .id("catalog-content-top")
                        }
                    }
                    .padding(.vertical, 17)
                }
                .refreshable { await onRefresh() }
                .onChange(of: scrollGeneration) { _ in
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
                ForEach(lanes) { lane in
                    CatalogLaneRowView(
                        title: lane.title,
                        books: lane.books.map { bookRegistry.updatedBookMetadata($0) ?? $0 },
                        moreURL: lane.moreURL,
                        onSelect: onBookSelected,
                        onMoreTapped: onLaneMoreTapped,
                        showHeader: true,
                        isLoading: lane.isLoading || isOptimisticLoading
                    )
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
            EmptyView()
        }
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
