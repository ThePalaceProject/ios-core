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

    /// Feature-flag read seam (Wave 1b); resolved from the environment so the
    /// gating decision goes through the injected provider, not `.shared`.
    @Environment(\.appContainer) private var appContainer

    /// Subscribes to the developer-settings local override so the view
    /// re-renders the moment the dev toggle flips. The actual gating decision
    /// delegates to `appContainer.featureFlags.isContinuationCardsEnabled`,
    /// which combines the override (wins when set) with the Firebase Remote
    /// Config `continuation_cards_enabled` value (fallback). Reading the
    /// @AppStorage value inside `continuationCardsEnabled` registers the
    /// SwiftUI observation against the same UserDefaults key the dev toggle
    /// writes to. NOTE: the continuation cards are gated separately from the
    /// in-app mini-player (`inAppPlaybackNavEnabled`) so they roll out
    /// independently.
    @AppStorage("RemoteFeatureFlags.continuationCardsLocalOverride")
    private var continuationCardsLocalOverride: Bool = false

    /// Chevron "pin": when `false` the lane is manually pinned collapsed and
    /// ignores the scroll; when `true` (default) the scroll position drives it.
    @State private var continueExpanded: Bool = true

    /// Scroll-driven collapse progress (0 = expanded … 1 = collapsed), scrubbed
    /// CONTINUOUSLY by the catalog scroll offset so the card tracks the finger
    /// rather than snapping at a threshold. Held as `@State` (owned but NOT
    /// observed) so per-frame `progress` updates re-render only
    /// `ContinueRowSection` (which `@ObservedObject`s it), never the whole
    /// catalog body. See `ContinueCollapseModel`.
    @State private var continueCollapse = ContinueCollapseModel()

    private var continuationCardsEnabled: Bool {
        _ = continuationCardsLocalOverride  // trigger SwiftUI observation
        return appContainer.featureFlags.isContinuationCardsEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Feature-flagged (continuation_cards_enabled): hides the
            // Continue Reading / Continue Listening hero rows when off.
            // Gated independently of the in-app mini-player. The viewmodel
            // still runs (subscriptions stay live so the flag flip is
            // instant); only the rendering is gated.
            if continuationCardsEnabled {
                ContinueRowSection(
                    viewModel: activeSessions,
                    onResumeReading: onResumeReading,
                    onResumeListening: onResumeListening,
                    isExpanded: $continueExpanded,
                    collapse: continueCollapse
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
                .onChange(of: scrollGeneration) { _, _ in
                    accessibleWithAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("catalog-content-top", anchor: .top)
                    }
                }
                .modifier(CatalogScrollCollapseModifier(
                    model: continueCollapse,
                    isExpanded: continueExpanded
                ))
            }
        }
    }
}

// MARK: - Scroll-driven Continue-lane collapse

/// Drives the Continue lane's collapse progress CONTINUOUSLY from the catalog
/// scroll offset, so the card scrubs 0→1 (expanded→collapsed) exactly as fast
/// as the patron scrolls — attached to the finger, no independent animation
/// clock. Owned by `CatalogContentView` via `@State` (not `@StateObject`) so
/// per-frame `progress` writes re-render only `ContinueRowSection`.
@MainActor
final class ContinueCollapseModel: ObservableObject {
    /// 0 = fully expanded … 1 = fully collapsed.
    @Published var progress: CGFloat = 0

    /// Scroll offsets (points; 0 == top) across which the card scrubs 0→1. The
    /// lower bound leaves a little dead-zone at the very top so the lane doesn't
    /// twitch on tiny rubber-band overscroll.
    private static let band: ClosedRange<CGFloat> = 8...104

    /// Scrub toward the offset-implied target. Direct assignment while scrubbing
    /// (tracks the finger, both directions); a spring only absorbs a big jump
    /// (e.g. the programmatic scroll-to-top on an entry-point switch) so it never
    /// teleports.
    func update(forOffset offset: CGFloat, reduceMotion: Bool) {
        let span = Self.band.upperBound - Self.band.lowerBound
        let target = min(max((offset - Self.band.lowerBound) / span, 0), 1)
        let delta = abs(target - progress)
        if delta > 0.2 {
            withAnimation(PalaceMotion.resolved(PalaceMotion.springy, reduceMotion: reduceMotion)) {
                progress = target
            }
        } else if delta > 0.0005 {
            progress = target
        }
    }

    /// On scroll rest, settle to the nearer end so the card never parks
    /// half-collapsed mid-band.
    func settleIfMidBand(reduceMotion: Bool) {
        guard (0.02...0.98).contains(progress) else { return }
        withAnimation(PalaceMotion.resolved(PalaceMotion.springy, reduceMotion: reduceMotion)) {
            progress = progress > 0.4 ? 1 : 0
        }
    }
}

/// Feeds the catalog scroll offset into `ContinueCollapseModel` (iOS 18
/// `onScrollGeometryChange`). On iOS 17 the lane stays chevron-controlled only —
/// this is a no-op there. `isExpanded == false` (chevron pinned collapsed)
/// suspends scrubbing.
private struct CatalogScrollCollapseModifier: ViewModifier {
    let model: ContinueCollapseModel
    let isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    // Normalize so 0 == top; grows positive as the patron scrolls in.
                    geo.contentOffset.y + geo.contentInsets.top
                } action: { _, offset in
                    guard isExpanded else { return }   // chevron-pinned: ignore scroll
                    model.update(forOffset: offset, reduceMotion: reduceMotion)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .idle { model.settleIfMidBand(reduceMotion: reduceMotion) }
                }
        } else {
            content
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
