import SwiftUI
import PalacePreferences
import Combine
import PalaceUIKit
import PalaceBookModel

struct MyBooksView: View {
    @EnvironmentObject private var coordinator: NavigationCoordinator
    typealias DisplayStrings = Strings.MyBooksView
    @ObservedObject var model: MyBooksViewModel
    @State private var showSortSheet: Bool = false
    @StateObject private var logoObserver = CatalogLogoObserver()
    @State private var currentAccountUUID: String = ""
    @FocusState private var isSearchFocused: Bool
    private let appContainer: AppContainer
    let accountsManager: AccountsManager
    let settings: TPPSettings
    let bookRegistry: TPPBookRegistryProvider
    let samplePreviewManager: SamplePreviewManager

    init(model: MyBooksViewModel, appContainer: AppContainer) {
        self.model = model
        self.appContainer = appContainer
        self.accountsManager = appContainer.accountsManager
        self.settings = appContainer.settings
        self.bookRegistry = appContainer.bookRegistry
        self.samplePreviewManager = appContainer.samplePreviewManager
    }
    // Centralized sample preview manager overlay

    var body: some View {
        ZStack {
            if model.isLoading || DebugSettings.forceSkeletons {
                BookListSkeletonView(rows: 10)
                    .transition(.opacity)
            } else {
                mainContent
                    .transition(.opacity)
            }
        }
        .accessibleAnimation(PalaceMotion.gentle, value: model.isLoading)
        .background(Color(TPPConfiguration.backgroundColor()))
        .overlay(alignment: .bottom) { SamplePreviewBarView() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                LibraryNavTitleView(onTap: {
                    if let urlString = accountsManager.currentAccount?.homePageUrl, let url = URL(string: urlString) {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                })
                .id(logoObserver.token.uuidString + currentAccountUUID)
            }
            ToolbarItem(placement: .navigationBarLeading) { leadingBarButton }
            ToolbarItem(placement: .navigationBarTrailing) {
                if model.showSearchSheet {
                    Button(action: {
                        isSearchFocused = false
                        model.showSearchSheet = false
                        model.resetFilter()
                        model.searchQuery = ""
                    }, label: {
                        Text(Strings.Generic.cancel)
                    })
                } else {
                    trailingBarButton
                }
            }
        }
        .onAppear {
            model.isVisible = true
            model.showSearchSheet = false
            let account = accountsManager.currentAccount
            account?.logoDelegate = logoObserver
            account?.loadLogo()
            currentAccountUUID = account?.uuid ?? ""
            // Background refresh on appear — sync silently, UI updates via notifications
            model.refreshInBackground()
        }
        .onDisappear {
            model.isVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)) { _ in
            let account = accountsManager.currentAccount
            account?.logoDelegate = logoObserver
            account?.loadLogo()
            currentAccountUUID = account?.uuid ?? ""
        }
        .sheet(isPresented: $model.showLibraryAccountView) {
            UIViewControllerWrapper(
                TPPAccountList { account in
                    model.authenticateAndLoad(account: account)
                    model.showLibraryAccountView = false
                },
                updater: { _ in }
            )
        }
        .actionSheet(isPresented: $showSortSheet) { sortActionSheet }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ToggleSampleNotification")).receive(on: RunLoop.main)) { note in
            guard let info = note.userInfo as? [String: Any], let identifier = info["bookIdentifier"] as? String else { return }
            let action = (info["action"] as? String) ?? "toggle"
            if action == "close" {
                samplePreviewManager.close()
                return
            }
            if let book = bookRegistry.book(forIdentifier: identifier) ?? model.books.first(where: { $0.identifier == identifier }) {
                samplePreviewManager.toggle(for: book)
            }
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showSearchSheet { searchBar }
            FacetToolbarView(
                title: nil,
                showFilter: false,
                onSort: { showSortSheet = true },
                onFilter: {},
                currentSortTitle: model.facetViewModel.activeSort.localizedString
            )
            .accessibilityIdentifier(AccessibilityID.MyBooks.sortButton)
            content
        }
    }

    private var content: some View {
        GeometryReader { geometry in
            if model.showInstructionsLabel {
                ScrollView {
                    emptyView
                        .frame(minHeight: geometry.size.height)
                        .centered()
                }
                .refreshable { model.reloadData() }
            } else {
                ScrollView {
                    BookListView(
                        books: model.books,
                        isLoading: $model.isLoading,
                        onSelect: { book in presentBookDetail(for: book) }
                    )
                }
                .accessibilityIdentifier(AccessibilityID.MyBooks.gridView)
                .scrollIndicators(.visible)
                .refreshable { model.reloadData() }
                .animation(.easeInOut(duration: 0.3), value: model.books.count)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture().onChanged { _ in
                    if model.showSearchSheet {
                        model.resetFilter()
                        model.searchQuery = ""
                    }
                })
            }
        }
    }

    private func presentBookDetail(for book: TPPBook) {
        coordinator.store(book: book)
        coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
    }

    private var searchBar: some View {
        HStack {
            // PP-4421: explicit prompt with `.secondary` foreground overrides
            // the default `.placeholderText` (~30% gray) that reads as
            // disabled. Entered text retains its own .foregroundColor.
            TextField(DisplayStrings.searchBooks, text: $model.searchQuery,
                      prompt: Text(DisplayStrings.searchBooks).foregroundStyle(.secondary))
                .searchBarStyle()
                .focused($isSearchFocused)
                .onChange(of: model.searchQuery) { _, query in
                    guard model.showSearchSheet else { return }
                    Task {
                        await model.filterBooks(query: query)
                    }
                }
            Button(action: clearSearch, label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.gray)
            })
            .accessibilityLabel(Strings.Generic.clearSearch)
        }
        .padding(.horizontal)
        .onChange(of: model.showSearchSheet) { _, isShown in
            if isShown {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFocused = true
                }
            }
        }
    }

    private func clearSearch() {
        model.resetFilter()
        model.searchQuery = ""
    }

    private var loadingOverlay: some View {
        ProgressView()
            .scaleEffect(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.5).ignoresSafeArea())
    }

    private var leadingBarButton: some View {
        Button(action: { model.selectNewLibrary.toggle() }, label: {
            ImageProviders.MyBooksView.myLibraryIcon
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        })
        .accessibilityIdentifier(AccessibilityID.Settings.manageLibrariesButton)
        .accessibilityLabel(Strings.Generic.switchLibrary)
        .actionSheet(isPresented: $model.selectNewLibrary, content: { libraryPicker })
    }

    private var trailingBarButton: some View {
        Button(action: { withAnimation(UIAccessibility.isReduceMotionEnabled ? .none : .default) { model.showSearchSheet.toggle() } }, label: {
            ImageProviders.MyBooksView.search
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        })
        .accessibilityIdentifier(AccessibilityID.MyBooks.searchButton)
        .accessibilityLabel(Strings.Generic.searchBooks)
    }

    private var sortActionSheet: ActionSheet {
        let author = ActionSheet.Button.default(Text(Strings.FacetView.author)) {
            model.facetViewModel.activeSort = .author
        }
        let title = ActionSheet.Button.default(Text(Strings.FacetView.title)) {
            model.facetViewModel.activeSort = .title
        }
        return ActionSheet(title: Text(DisplayStrings.sortBy), buttons: [author, title, .cancel()])
    }

    private var libraryPicker: ActionSheet {
        ActionSheet(
            title: Text(DisplayStrings.findYourLibrary),
            buttons: existingLibraryButtons() + [addLibraryButton, .cancel()]
        )
    }

    private func existingLibraryButtons() -> [ActionSheet.Button] {
        settings.settingsAccountsList.map { account in
            .default(Text(account.name)) {
                model.loadAccount(account)
                model.showLibraryAccountView = false
                model.selectNewLibrary = false
            }
        }
    }

    private var addLibraryButton: ActionSheet.Button {
        .default(Text(DisplayStrings.addLibrary)) { model.showLibraryAccountView = true }
    }

    private var emptyView: some View {
        // The CTA is rendered OUTSIDE `ContentUnavailableView` (below its title +
        // description) rather than in its `actions:` slot: that slot styles
        // buttons as plain tinted text links, so the button read as a bare link.
        // It uses the app's standard filled-CTA style — an explicit `Color.blue`
        // capsule with white text (matching the catalog "Reload" button,
        // `CatalogView.swift`) rather than `.borderedProminent`, which the app
        // doesn't use elsewhere and which would inherit the tab bar's neutral
        // tint. Explicit `Color.blue` keeps it brand-consistent regardless of tint.
        VStack(spacing: 20) {
            ContentUnavailableView {
                // Icon intentionally removed for now (was `systemImage:
                // "books.vertical"`, added in #1203/PP-4747). Copy unchanged — a
                // plain title `Text` renders the same words without the SF Symbol.
                Text(DisplayStrings.emptyViewTitle)
            } description: {
                Text(DisplayStrings.emptyViewMessage)
            }
            .fixedSize(horizontal: false, vertical: true)

            Button {
                appContainer.tabRouterHub.navigate(to: .catalog)
            } label: {
                Text(DisplayStrings.browseCatalog)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .cornerRadius(8)
            }
        }
        .transition(.opacity)
        .accessibilityIdentifier(AccessibilityID.MyBooks.emptyStateView)
    }

    private func setupTabBarForiPad() {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            UITabBar.appearance().isHidden = false
        }
        #endif
    }
}

extension View {
    func searchBarStyle() -> some View {
        self.padding(8)
            .textFieldStyle(.automatic)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(10)
            .padding(.vertical, 8)
    }

    func centered() -> some View {
        self.horizontallyCentered().verticallyCentered()
    }
}
