import SwiftUI
import UIKit

// MARK: - Accessibility focus (list callout when entering Holds)
private enum HoldsAccessibilityFocus: Hashable {
    case list
}

struct HoldsView: View {
    @EnvironmentObject private var coordinator: NavigationCoordinator
    typealias DisplayStrings = Strings.HoldsView

    @StateObject private var model = HoldsViewModel()
    @AccessibilityFocusState private var accessibilityFocus: HoldsAccessibilityFocus?
    @StateObject private var logoObserver = CatalogLogoObserver()
    @State private var currentAccountUUID: String = AccountsManager.shared.currentAccount?.uuid ?? ""
    private var allBooks: [TPPBook] {
        model.reservedBookVMs.map { $0.book } + model.heldBookVMs.map { $0.book }
    }
    var body: some View {
        ZStack {
            mainContent
                .background(Color(TPPConfiguration.backgroundColor()))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        LibraryNavTitleView(onTap: {
                            if let urlString = AccountsManager.shared.currentAccount?.homePageUrl, let url = URL(string: urlString) {
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
                    model.showLibraryAccountView = false
                    let account = AccountsManager.shared.currentAccount
                    account?.logoDelegate = logoObserver
                    account?.loadLogo()
                    currentAccountUUID = account?.uuid ?? ""
                    if !model.isLoading, UIAccessibility.isVoiceOverRunning {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            let value = Strings.SearchAnnouncements.searchResultsListValue(bookCount: model.visibleBooks.count)
                            UIAccessibility.post(notification: .announcement, argument: "\(Strings.Generic.holdsListLabel), \(value)")
                            if !model.visibleBooks.isEmpty {
                                accessibilityFocus = .list
                            }
                        }
                    }
                }
                .onChange(of: model.isLoading) { isLoading in
                    if !isLoading, UIAccessibility.isVoiceOverRunning {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            let value = Strings.SearchAnnouncements.searchResultsListValue(bookCount: model.visibleBooks.count)
                            UIAccessibility.post(notification: .announcement, argument: "\(Strings.Generic.holdsListLabel), \(value)")
                            if !model.visibleBooks.isEmpty {
                                accessibilityFocus = .list
                            }
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)) { _ in
                    let account = AccountsManager.shared.currentAccount
                    account?.logoDelegate = logoObserver
                    account?.loadLogo()
                    currentAccountUUID = account?.uuid ?? ""
                }
                .sheet(isPresented: $model.showLibraryAccountView) {
                    UIViewControllerWrapper(
                        TPPAccountList { account in
                            DispatchQueue.main.async {
                                model.loadAccount(account)
                            }
                        },
                        updater: { _ in }
                    )
                }

            if model.isLoading {
                loadingOverlay
            }
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.syncError {
                syncErrorBanner(error)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if model.showSearchSheet {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { geometry in
            if model.isLoading {
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
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Strings.Generic.holdsListLabel)
                .accessibilityValue(Strings.SearchAnnouncements.searchResultsListValue(bookCount: model.visibleBooks.count))
                .accessibilityHint(Strings.SearchAnnouncements.searchResultsListHint)
                .accessibilityFocused($accessibilityFocus, equals: .list)
                .scrollIndicators(.visible)
                .refreshable { model.refresh() }
                .dismissKeyboardOnTap()
                .accessibilityIdentifier(AccessibilityID.Holds.scrollView)
            }
        }
    }

    private func syncErrorBanner(_ error: HoldsViewModel.SyncError) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.HoldsView.syncFailedTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text(error.message)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
            }
            Spacer()
            Button {
                withAnimation { model.dismissSyncError() }
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(.white.opacity(0.8))
                    .font(.caption)
            }
            .accessibilityLabel(Strings.Generic.close)
        }
        .padding(12)
        .background(Color.red.opacity(0.85))
        .accessibilityIdentifier(AccessibilityID.Holds.syncErrorBanner)
    }

    /// Placeholder text when there are no holds at all
    private var emptyView: some View {
        Text(DisplayStrings.emptyMessage)
            .multilineTextAlignment(.center)
            .foregroundColor(Color(white: 0.667))
            .background(Color(TPPConfiguration.backgroundColor()))
            .palaceFont(.body)
            .padding(.horizontal, 24)
            .padding(.top, 100)
    }

    /// Semi‐transparent loading overlay
    private var loadingOverlay: some View {
        ProgressView()
            .scaleEffect(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.5).ignoresSafeArea())
    }

    /// Leading bar button: "Pick a new library"
    private var leadingBarButton: some View {
        Button {
            model.selectNewLibrary = true
        } label: {
            ImageProviders.MyBooksView.myLibraryIcon
        }
        .accessibilityIdentifier(AccessibilityID.Holds.libraryButton)
        .accessibilityLabel(Strings.Generic.switchLibrary)
        .actionSheet(isPresented: $model.selectNewLibrary) {
            var buttons: [ActionSheet.Button] = TPPSettings.shared.settingsAccountsList.map { account in
                .default(Text(account.name)) {
                    model.loadAccount(account)
                }
            }
            buttons.append(.default(Text(Strings.MyBooksView.addLibrary)) {
                model.showLibraryAccountView = true
            })
            buttons.append(.cancel())
            return ActionSheet(
                title: Text(NSLocalizedString(DisplayStrings.findYourLibrary, comment: "")),
                buttons: buttons
            )
        }
    }

    private var trailingBarButton: some View {
        Button {
            withAnimation(UIAccessibility.isReduceMotionEnabled ? .none : .default) { model.showSearchSheet.toggle() }
        } label: {
            ImageProviders.MyBooksView.search
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
                .onChange(of: model.searchQuery) { query in
                    Task { await model.filterBooks(query: query) }
                }
            Button(action: clearSearch, label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
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
    /// • The SwiftUI view uses `HoldsViewModel()` under the hood.
    /// • We set the navigation title and the tab-bar image here.
    @MainActor
    @objc static func makeSwiftUIView() -> UIViewController {
        let holdsRoot = HoldsView()

        let hosting = UIHostingController(rootView: holdsRoot)
        hosting.title = Strings.HoldsView.holds
        hosting.tabBarItem.image = UIImage(named: "Holds")

        return hosting
    }
}
