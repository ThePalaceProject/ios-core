import SwiftUI
import PalacePreferences
import UIKit
import PalaceLogging
import PalaceBookModel

struct CatalogView: View {
    // MARK: - Properties
    @EnvironmentObject private var coordinator: NavigationCoordinator
    @StateObject private var viewModel: CatalogViewModel
    @StateObject private var logoObserver = CatalogLogoObserver()
    /// Module B (swarm_0b7616e7) — drives the Continue Listening +
    /// Continue Reading rows at the top of the catalog. Held as
    /// `@ObservedObject` so the owner (`AppTabHostView`) controls the
    /// lifecycle — the viewmodel is process-wide and outlives any single
    /// CatalogView instance (library swaps + tab-switches re-create
    /// `CatalogView`, not the viewmodel).
    @ObservedObject private var activeSessionsViewModel: ActiveSessionsViewModel
    @State private var currentAccountUUID: String = ""
    @State private var showSearch: Bool = false

    private let accountsManager: AccountsManager
    /// Resolves `ReaderService` + `AudiobookSessionPresenter` for the
    /// resume taps. Held as an `AppContainer` so test injection can
    /// supply a spy presenter via `withAudiobookSessionPresenter(_:)`.
    private let appContainer: AppContainer

    // MARK: - Initialization
    init(
        viewModel: CatalogViewModel,
        activeSessionsViewModel: ActiveSessionsViewModel,
        accountsManager: AccountsManager = AppContainer.production().accountsManager,
        appContainer: AppContainer = AppContainer.production()
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.activeSessionsViewModel = activeSessionsViewModel
        self.accountsManager = accountsManager
        self.appContainer = appContainer
    }

    // MARK: - Body
    var body: some View {
        content
            .padding(.top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { toolbarContent }
            .onAppear {
                currentAccountUUID = accountsManager.currentAccount?.uuid ?? ""
                setupCurrentAccount()
                coordinator.clearAllCatalogFilterStates()
            }
            .task { await viewModel.load() }
            .onReceive(NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)) { _ in
                handleAccountChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .AppTabSelectionDidChange)) { _ in
                handleTabChange()
            }
    }
}

private extension CatalogView {
    // MARK: - Toolbar and UI Components
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            LibraryNavTitleView(onTap: { openLibraryHome() })
                .id(logoObserver.token.uuidString + currentAccountUUID)
                .accessibilityIdentifier(AccessibilityID.Catalog.libraryLogo)
        }
        ToolbarItem(placement: .navigationBarLeading) {
            // PP-4821: the top-left Palace icon is static branding only. Library
            // switching lives solely in Settings now, so this is a plain image —
            // not a Button — and stays hidden from VoiceOver (no button trait, no
            // "Switch Library" announcement).
            ImageProviders.MyBooksView.myLibraryIcon
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHidden(true)
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            if showSearch {
                Button(action: { dismissSearch() }, label: {
                    Text(Strings.Generic.cancel)
                        .frame(minHeight: 44)
                })
                .accessibilityIdentifier(AccessibilityID.Search.cancelButton)
            } else {
                Button(action: { presentSearch() }, label: {
                    ImageProviders.MyBooksView.search
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                })
                .accessibilityIdentifier(AccessibilityID.Catalog.searchButton)
                .accessibilityLabel(Strings.Generic.searchCatalog)
            }
        }
    }

    @ViewBuilder
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showSearch {
                CatalogSearchView(
                    repository: viewModel.searchRepository,
                    baseURL: viewModel.searchBaseURL,
                    books: viewModel.state.allBooks,
                    onBookSelected: presentBookDetail
                )
            } else {
                catalogStateView
                    .accessibleAnimation(PalaceMotion.gentle, value: isCatalogLoading)
            }
        }
    }

    /// Whether the catalog is in its initial-load (skeleton) state. Drives the
    /// skeleton -> content opacity cross-fade.
    var isCatalogLoading: Bool {
        if case .loading = viewModel.state { return true }
        return false
    }

    @ViewBuilder
    private var catalogStateView: some View {
        // Debug skeleton verification (PP-4797): force the initial-load skeleton
        // regardless of the feed state machine so it can be inspected on the sim
        // in both appearances. No-op in release (DebugSettings.forceSkeletons is
        // a compile-time `false`).
        if DebugSettings.forceSkeletons {
            skeletonList
                .accessibilityIdentifier(AccessibilityID.Catalog.loadingIndicator)
                .transition(.opacity)
        } else {
        switch viewModel.state {
        case .loading:
            skeletonList
                .accessibilityIdentifier(AccessibilityID.Catalog.loadingIndicator)
                .transition(.opacity)

        case .error(let message, let sideloadedLanes):
            errorView(message: message, sideloadedLanes: sideloadedLanes)

        case .offline(let sideloadedLanes):
            offlineView(sideloadedLanes: sideloadedLanes)

        case .loaded(let catalogContent), .applyingFacet(let catalogContent):
            CatalogContentView(
                content: catalogContent,
                isOptimisticLoading: viewModel.state.isApplyingFacet,
                scrollGeneration: viewModel.scrollGeneration,
                onBookSelected: presentBookDetail,
                onLaneMoreTapped: { title, url in
                    coordinator.push(.catalogLaneMore(title: title, url: url))
                },
                onEntryPointSelected: { facet in
                    Task { await viewModel.applyEntryPoint(facet) }
                },
                onFacetSelected: { facet in
                    Task { await viewModel.applyFacet(facet) }
                },
                onRefresh: { await viewModel.refresh() },
                activeSessions: activeSessionsViewModel,
                onResumeReading: { book in resumeReading(book) },
                onResumeListening: { book in resumeListening(book) }
            )
            .accessibilityIdentifier(AccessibilityID.Catalog.scrollView)
            .accessibilityLabel(Strings.Generic.catalogRegion)
            .accessibilityElement(children: .contain)
            .transition(.opacity)

        case .switchingEntryPoint(let selectors):
            CatalogContentView.switchingEntryPointView(
                selectors: selectors,
                onEntryPointSelected: { facet in
                    Task { await viewModel.applyEntryPoint(facet) }
                },
                onRefresh: { await viewModel.refresh() }
            )
        }
        }
    }

    private func errorView(message: String, sideloadedLanes: [CatalogLaneModel]) -> some View {
        failureView(sideloadedLanes: sideloadedLanes) { errorBanner(message: message) }
    }

    /// The feed-error banner (headline + message + Reload). Extracted from
    /// `errorView` so it can render either full-screen-centered (no side-loaded
    /// books) or as a header above the Side Loaded lane (F-1).
    private func errorBanner(message: String) -> some View {
        VStack(spacing: 16) {
            Text(Strings.Generic.error)
                .font(.headline)
                .foregroundStyle(.red)

            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier(AccessibilityID.Catalog.errorView)

            Button(action: {
                Task { await viewModel.forceRefresh() }
            }, label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .accessibilityHidden(true)
                    Text(Strings.Generic.reload)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .foregroundStyle(.white)
                .cornerRadius(8)
            })
        }
    }

    /// Offline state (PP-4578): shown when the catalog load fails because the
    /// device has no connectivity. Unlike `errorView`, it offers no Reload
    /// (which cannot succeed offline) and instead points the patron to their
    /// downloaded books. The catalog reloads automatically when connectivity
    /// returns (handled in `CatalogViewModel`).
    private func offlineView(sideloadedLanes: [CatalogLaneModel]) -> some View {
        failureView(sideloadedLanes: sideloadedLanes) { offlineBanner }
    }

    /// The offline banner (wifi.slash + message + Go-to-My-Books). Extracted so
    /// it can render either full-screen-centered or above the Side Loaded lane
    /// (F-1), mirroring `errorBanner`.
    private var offlineBanner: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(Strings.Catalog.offlineTitle)
                .font(.headline)

            Text(Strings.Catalog.offlineMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: {
                appContainer.tabRouterHub.navigate(to: .myBooks)
            }, label: {
                Text(Strings.Catalog.offlineGoToMyBooks)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .cornerRadius(8)
            })
            .accessibilityIdentifier(AccessibilityID.Catalog.goToMyBooksButton)
        }
        .accessibilityIdentifier(AccessibilityID.Catalog.offlineStateView)
    }

    /// F-1 composition seam. When there are no side-loaded lanes the banner
    /// fills the screen exactly as it did before F-1 (byte-identical layout).
    /// When the Side Loaded lane is present, the banner becomes a header above
    /// the lane inside a scroll view — the feed failure stays visible AND the
    /// imported books remain reachable.
    @ViewBuilder
    private func failureView<Banner: View>(
        sideloadedLanes: [CatalogLaneModel],
        @ViewBuilder banner: () -> Banner
    ) -> some View {
        if sideloadedLanes.isEmpty {
            banner()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    banner()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    ForEach(sideloadedLanes) { lane in
                        CatalogLaneRowView(
                            title: lane.title,
                            books: lane.books,
                            moreURL: lane.moreURL,
                            onSelect: presentBookDetail,
                            onMoreTapped: { title, url in
                                coordinator.push(.catalogLaneMore(title: title, url: url))
                            },
                            showHeader: true
                        )
                    }
                }
                .padding(.vertical, 17)
            }
        }
    }

    func presentBookDetail(_ book: TPPBook) {
        coordinator.store(book: book)
        coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
    }

    func openLibraryHome() {
        if let urlString = accountsManager.currentAccount?.homePageUrl, let url = URL(string: urlString) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    func presentSearch() {
        withAnimation(UIAccessibility.isReduceMotionEnabled ? .none : .default) { showSearch = true }
    }

    func dismissSearch() {
        withAnimation(UIAccessibility.isReduceMotionEnabled ? .none : .default) {
            showSearch = false
        }
    }

    func handleTabChange() {
        if showSearch {
            dismissSearch()
        }
    }

    // MARK: - Account Management
    func setupCurrentAccount() {
        let account = accountsManager.currentAccount
        account?.logoDelegate = logoObserver
        account?.loadLogo()
        currentAccountUUID = account?.uuid ?? ""
    }

    func handleAccountChange() {
        if showSearch {
            dismissSearch()
        }

        let account = accountsManager.currentAccount
        account?.logoDelegate = logoObserver
        account?.loadLogo()
        currentAccountUUID = account?.uuid ?? ""

        coordinator.clearAllCatalogFilterStates()

        Task { await viewModel.handleAccountChange() }
    }

    // MARK: - Computed Properties
    var allBooks: [TPPBook] {
        viewModel.state.allBooks
    }

    // MARK: - Subviews

    /// Top-level skeleton used during initial load.
    ///
    /// Mirrors `CatalogContentView`'s loaded layout so the first lane lands at
    /// the same y in both states and does not pop when content arrives (PP-4752):
    ///   * `CatalogEntryPointsSkeletonView` traces the "All · Ebooks ·
    ///     Audiobooks" segmented selector that renders above the lanes once the
    ///     grouped feed loads (reserving its ~44pt footprint).
    ///   * the lane scroller carries a 34pt vertical inset — matching
    ///     `CatalogContentView`'s doubled `.padding(.vertical, 17)` (the outer
    ///     `LazyVStack` plus the inner feed content) — so the first lane's top
    ///     inset equals the loaded feed's.
    @ViewBuilder
    var skeletonList: some View {
        VStack(alignment: .leading, spacing: 0) {
            CatalogEntryPointsSkeletonView()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(0..<3, id: \.self) { _ in
                        CatalogLaneSkeletonView()
                    }
                }
                // 17 (outer LazyVStack) + 17 (feed content) in CatalogContentView.
                .padding(.vertical, 34)
            }
        }
    }
}

// MARK: - Module B (swarm_0b7616e7) — Continue Reading / Listening seams
//
// These two helpers are the production seams that `ContinueRowSection`'s
// tap closures route through (wired in `CatalogContentView`'s
// `onResumeReading` / `onResumeListening` parameters). They live in a
// file-internal extension (not `private`) so
// `CatalogViewContinueRowsIntegrationTests` can drive them directly
// without spinning up the full SwiftUI view tree. `ReaderService` is
// concrete (not protocol-extracted yet) — the integration test for the
// reader path uses a source-level wiring check; see the test file's
// "Test 3" header for the scope-deferral rationale.

extension CatalogView {
    /// Continue Reading row tap. Routes to the existing reader-open flow
    /// (`ReaderService.openEPUB` for `.epub`, `.openPDF` for `.pdf`).
    /// Audiobook content is filtered upstream by `RecentlyReadingService`,
    /// so any non-epub / non-pdf here is a programming error — we no-op
    /// silently rather than crash, and rely on the source filter as the
    /// honest contract.
    @MainActor
    func resumeReading(_ book: TPPBook) {
        let readerService = appContainer.readerService
        switch book.defaultBookContentType {
        case .epub:
            readerService.openEPUB(book)
        case .pdf:
            readerService.openPDF(book, onFinish: nil)
        case .audiobook, .unsupported, .streamingHTML:
            // Defensive: upstream `RecentlyReadingService` filters these
            // out; logging keeps the silent no-op observable in production
            // if the filter ever drifts. PP-4161: streamingHTML titles
            // belong in the streaming reader, not the continue-reading row —
            // RecentlyReadingService is expected to filter them as it does
            // .audiobook.
            Log.warn(#file, "resumeReading invoked for unsupported content type — skipping")
        }
    }

    /// Continue Listening row tap. Two branches per the polish-phase
    /// fallback (in-app-nav-polish-2026-06-02):
    ///   1. If there's an active audiobook session for the tapped book,
    ///      expand the player (no need to re-open — same idiom as before).
    ///   2. Otherwise (cold-launch fallback case — no live session, the
    ///      item came from `recentlyOpenedAudiobook()`), trigger the
    ///      audiobook open flow. The session manager calls
    ///      `presenter.presentOnFirstOpen()` synchronously, so the
    ///      full-screen player surfaces immediately while the async
    ///      readiness gate proceeds.
    @MainActor
    func resumeListening(_ book: TPPBook) {
        let session = appContainer.audiobookSession
        if let active = session.currentBook, active.identifier == book.identifier {
            appContainer.audiobookSessionPresenter.expand()
            return
        }
        // Cold-launch fallback: no live session for this book. Kick off
        // openAudiobook(_:startPlaying:) — user explicitly tapped
        // Continue, so `startPlaying: true` matches user intent. Result
        // is intentionally discarded here because the session manager
        // surfaces errors through `errorPublisher` (consumed by
        // AudiobookSessionPresenter) — no double-reporting at the
        // call site.
        Task { @MainActor in
            _ = await session.openAudiobook(book, startPlaying: true)
        }
    }
}
