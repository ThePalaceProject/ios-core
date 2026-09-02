import SwiftUI
import UIKit
import PalaceBookModel

struct HoldsView: View {
    @EnvironmentObject private var coordinator: NavigationCoordinator
    typealias DisplayStrings = Strings.HoldsView

    private let appContainer: AppContainer
    @StateObject private var model: HoldsViewModel
    @StateObject private var logoObserver = CatalogLogoObserver()
    @State private var currentAccountUUID: String = ""

    init(appContainer: AppContainer) {
        self.appContainer = appContainer
        _model = StateObject(wrappedValue: HoldsViewModel(appContainer: appContainer))
    }
    private var allBooks: [TPPBook] {
        model.reservedBookVMs.map { $0.book } + model.heldBookVMs.map { $0.book }
    }
    var body: some View {
        ZStack {
            mainContent
                .background(Color(TPPConfiguration.backgroundColor()))
                .overlay(alignment: .bottom) { SamplePreviewBarView() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        LibraryNavTitleView(onTap: {
                            if let urlString = appContainer.accountsManager.currentAccount?.homePageUrl, let url = URL(string: urlString) {
                                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                            }
                        })
                        .id(logoObserver.token.uuidString + currentAccountUUID)
                    }
                    ToolbarItem(placement: .navigationBarLeading) { leadingBarButton }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if model.showSearchSheet {
                            Button(action: {
                                withAnimation(UIAccessibility.isReduceMotionEnabled ? .none : .default) {
                                    model.showSearchSheet = false
                                    model.searchQuery = ""
                                }
                            }, label: {
                                Text(Strings.Generic.cancel)
                            })
                        } else {
                            trailingBarButton
                        }
                    }
                }
                .onAppear {
                    model.showSearchSheet = false
                    let account = appContainer.accountsManager.currentAccount
                    account?.logoDelegate = logoObserver
                    account?.loadLogo()
                    currentAccountUUID = account?.uuid ?? ""
                    model.refreshInBackground()
                }
                .onDisappear {
                    model.isVisible = false
                }
                .onReceive(NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)) { _ in
                    let account = appContainer.accountsManager.currentAccount
                    account?.logoDelegate = logoObserver
                    account?.loadLogo()
                    currentAccountUUID = account?.uuid ?? ""
                }
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let syncError = model.syncError {
                syncErrorBanner(syncError)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if model.showSearchSheet {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .accessibleAnimation(PalaceMotion.standard, value: model.syncError?.message)
    }

    private func syncErrorBanner(_ error: HoldsViewModel.SyncError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
            Button {
                model.dismissSyncError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Strings.Generic.close)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { geometry in
            if model.isLoading || DebugSettings.forceSkeletons {
                BookListSkeletonView(rows: 10)
                    .accessibilityIdentifier(AccessibilityID.Holds.loadingIndicator)
            } else if model.visibleBooks.isEmpty {
                ScrollView {
                    emptyView
                        .frame(minHeight: geometry.size.height)
                        .centered()
                }
                .refreshable { model.refresh() }
                .accessibilityIdentifier(AccessibilityID.Holds.emptyStateView)
            } else {
                ScrollView {
                    BookListView(
                        books: model.visibleBooks,
                        isLoading: $model.isLoading,
                        onSelect: { book in presentBookDetail(book) }
                    )
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.visible)
                .refreshable { model.refresh() }
                .dismissKeyboardOnTap()
                .accessibilityIdentifier(AccessibilityID.Holds.scrollView)
                .animation(.easeInOut(duration: 0.3), value: model.visibleBooks.count)
            }
        }
    }

    /// Empty state shown when the patron has no reserved or held books.
    private var emptyView: some View {
        ContentUnavailableView {
            // Icon intentionally removed for now (was `systemImage: "clock"`,
            // added in #1203/PP-4747). Copy unchanged — a plain title `Text`
            // renders the same words without the SF Symbol above them.
            Text(DisplayStrings.emptyTitle)
        } description: {
            Text(DisplayStrings.emptyMessage)
        }
        .transition(.opacity)
        .padding(.horizontal, 24)
    }

    /// Leading bar item: the Palace icon, branding only.
    private var leadingBarButton: some View {
        // PP-4821 / PP-5066: library switching lives solely in Settings. PP-4821
        // made this a plain image on the Catalog but missed Holds and My Books,
        // leaving the switcher reachable — and announced to VoiceOver as
        // "Switch Library" — on exactly the two screens it was removed from.
        ImageProviders.MyBooksView.myLibraryIcon
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHidden(true)
    }

    private var trailingBarButton: some View {
        Button {
            withAnimation(UIAccessibility.isReduceMotionEnabled ? .none : .default) { model.showSearchSheet.toggle() }
        } label: {
            ImageProviders.MyBooksView.search
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(AccessibilityID.Holds.searchButton)
        .accessibilityLabel(NSLocalizedString("Search Holds", comment: ""))
    }

    private func presentBookDetail(_ book: TPPBook) {
        coordinator.store(book: book)
        coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
    }

    private var searchBar: some View {
        HStack {
            TextField(NSLocalizedString("Search Holds", comment: ""), text: $model.searchQuery)
                .searchBarStyle()
                .accessibilityIdentifier(AccessibilityID.Holds.searchField)
                .onChange(of: model.searchQuery) { _, query in
                    Task { await model.filterBooks(query: query) }
                }
            Button(action: clearSearch, label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.gray)
            })
            .accessibilityLabel(Strings.Generic.clearSearch)
        }
        .padding(.horizontal)
    }

    private func clearSearch() {
        Task {
            model.searchQuery = ""
            await model.filterBooks(query: "")
        }
    }
}

@objc final class TPPHoldsViewController: NSObject {

    /// Returns a `UINavigationController` containing our SwiftUI `HoldsView`.
    /// Composition root: hands the production `AppContainer` to the view,
    /// which in turn constructs `HoldsViewModel` with live services.
    @MainActor
    @objc static func makeSwiftUIView() -> UIViewController {
        let holdsRoot = HoldsView(appContainer: .production())

        let hosting = UIHostingController(rootView: holdsRoot)
        hosting.title = NSLocalizedString("Holds", comment: "Nav title for Holds")
        hosting.tabBarItem.image = UIImage(named: "Holds")

        return hosting
    }
}
