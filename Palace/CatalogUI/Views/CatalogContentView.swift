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
    /// Module B (swarm_0b7616e7) — drives the "Continue Listening" +
    /// "Continue Reading" hero rows prepended above `selectorsView`.
    /// Injected from `CatalogView`; non-optional so the view always has a
    /// source of truth (an empty viewmodel renders zero rows — see
    /// `ContinueRowSection`).
    @ObservedObject var activeSessions: ActiveSessionsViewModel
    /// Tap on a Continue Reading card. Routed by `CatalogView` to
    /// `ReaderService.openEPUB` / `.openPDF` per content type.
    let onResumeReading: (TPPBook) -> Void
    /// Tap on a Continue Listening card. Routed by `CatalogView` to
    /// `AudiobookSessionPresenter.expand()` so the full player surfaces
    /// (§11 row 3, design doc).
    let onResumeListening: (TPPBook) -> Void
    var bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry

    /// Subscribes to the developer-settings local override so the view
    /// re-renders the moment the dev toggle flips. The actual gating
    /// decision delegates to `RemoteFeatureFlags.shared
    /// .isInAppPlaybackNavEnabled`, which combines the override (wins
    /// when set) with the Firebase Remote Config `in_app_playback_nav_enabled`
    /// value (fallback). Reading the @AppStorage value inside
    /// `inAppPlaybackNavEnabled` registers the SwiftUI observation
    /// against the same UserDefaults key the dev toggle writes to.
    @AppStorage("RemoteFeatureFlags.inAppPlaybackNavLocalOverride")
    private var inAppPlaybackNavLocalOverride: Bool = false

    private var inAppPlaybackNavEnabled: Bool {
        _ = inAppPlaybackNavLocalOverride  // trigger SwiftUI observation
        return RemoteFeatureFlags.shared.isInAppPlaybackNavEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Feature-flagged (in_app_playback_nav_enabled): hides the
            // Continue Reading / Continue Listening hero rows when off.
            // The viewmodel still runs (subscriptions stay live so the
            // flag flip is instant); only the rendering is gated.
            if inAppPlaybackNavEnabled {
                ContinueRowSection(
                    viewModel: activeSessions,
                    onResumeReading: onResumeReading,
                    onResumeListening: onResumeListening
                )
            }

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
