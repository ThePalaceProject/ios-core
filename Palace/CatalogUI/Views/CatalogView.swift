import SwiftUI
import UIKit
import PalaceLogging

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
    @State private var showAccountDialog: Bool = false
    @State private var showAddLibrarySheet: Bool = false
    @State private var showSearch: Bool = false

    private let accountsManager: AccountsManager
    private let settings: TPPSettings
    /// Resolves `ReaderService` + `AudiobookSessionPresenter` for the
    /// resume taps. Held as an `AppContainer` so test injection can
    /// supply a spy presenter via `withAudiobookSessionPresenter(_:)`.
    private let appContainer: AppContainer

    // MARK: - Initialization
    init(
        viewModel: CatalogViewModel,
        activeSessionsViewModel: ActiveSessionsViewModel,
        accountsManager: AccountsManager = AppContainer.production().accountsManager,
        settings: TPPSettings = AppContainer.production().settings,
        appContainer: AppContainer = AppContainer.production()
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.activeSessionsViewModel = activeSessionsViewModel
        self.accountsManager = accountsManager
        self.settings = settings
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
            .sheet(isPresented: $showAddLibrarySheet) { addLibrarySheet }
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
            Button(action: { showAccountDialog = true }, label: {
                ImageProviders.MyBooksView.myLibraryIcon
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            })
            .accessibilityIdentifier(AccessibilityID.Catalog.accountButton)
            .accessibilityLabel(Strings.Generic.switchLibrary)
            .actionSheet(isPresented: $showAccountDialog) { libraryPicker }
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

    private var libraryPicker: ActionSheet {
        var buttons: [ActionSheet.Button] = settings.settingsAccountsList.map { account in
            .default(Text(account.name)) {
                switchToAccount(account)
            }
        }
        buttons.append(.default(Text(Strings.MyBooksView.addLibrary)) {
            showAddLibrarySheet = true
        })
        buttons.append(.cancel())
        return ActionSheet(
            title: Text(Strings.MyBooksView.findYourLibrary),
            buttons: buttons
        )
    }

    @ViewBuilder
    var addLibrarySheet: some View {
        UIViewControllerWrapper(
            TPPAccountList { account in
                addAndSwitchToAccount(account)
                showAddLibrarySheet = false
            },
            updater: { _ in }
        )
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
            }
        }
    }

    @ViewBuilder
    private var catalogStateView: some View {
        switch viewModel.state {
        case .loading:
            skeletonList
                .accessibilityIdentifier(AccessibilityID.Catalog.loadingIndicator)

        case .error(let message):
            errorView(message: message)

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

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Text(Strings.Generic.error)
                .font(.headline)
                .foregroundColor(.red)

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
                .foregroundColor(.white)
                .cornerRadius(8)
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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

    func switchToAccount(_ account: Account) {
        if let urlString = account.catalogUrl, let url = URL(string: urlString) {
            settings.accountMainFeedURL = url
        }

        accountsManager.currentAccount = account
        account.loadAuthenticationDocument { _ in }

        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        Task { await viewModel.refresh() }
    }

    func addAndSwitchToAccount(_ account: Account) {
        if !settings.settingsAccountIdsList.contains(account.uuid) {
            settings.settingsAccountIdsList.append(account.uuid)
        }
        switchToAccount(account)
    }

    // MARK: - Computed Properties
    var allBooks: [TPPBook] {
        viewModel.state.allBooks
    }

    // MARK: - Subviews

    /// Top-level skeleton used during initial load.
    @ViewBuilder
    var skeletonList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(0..<3, id: \.self) { _ in
                    CatalogLaneSkeletonView()
                }
            }
            .padding(.vertical, 17)
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
        case .audiobook, .unsupported:
            // Defensive: upstream `RecentlyReadingService` filters these
            // out; logging keeps the silent no-op observable in production
            // if the filter ever drifts.
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
