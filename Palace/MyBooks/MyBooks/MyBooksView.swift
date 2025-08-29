import SwiftUI
import Combine
import PalaceUIKit

struct MyBooksView: View {
  @EnvironmentObject private var coordinator: NavigationCoordinator
  typealias DisplayStrings = Strings.MyBooksView
  @ObservedObject var model: MyBooksViewModel
  @State private var showSortSheet: Bool = false
  @StateObject private var logoObserver = CatalogLogoObserver()
  @State private var currentAccountUUID: String = AccountsManager.shared.currentAccount?.uuid ?? ""

  var body: some View {
      ZStack {
        if model.isLoading {
          BookListSkeletonView(rows: 10, imageSize: CGSize(width: 100, height: 150))
        } else {
          mainContent
        }
      }
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
        ToolbarItem(placement: .navigationBarTrailing) { trailingBarButton }
      }
      .onAppear {
        model.showSearchSheet = false
        UITabBarController.showFloatingTabBar()
        let account = AccountsManager.shared.currentAccount
        account?.logoDelegate = logoObserver
        account?.loadLogo()
        currentAccountUUID = account?.uuid ?? ""
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
            model.authenticateAndLoad(account: account)
            model.showLibraryAccountView = false
          },
          updater: { _ in }
        )
      }
      .actionSheet(isPresented: $showSortSheet) { sortActionSheet }
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
      content
    }
  }

  private var content: some View {
    GeometryReader { geometry in
      if model.showInstructionsLabel {
        emptyView
          .frame(minHeight: geometry.size.height)
          .refreshable { model.reloadData() }
      } else {
        BookListView(
          books: model.books,
          isLoading: $model.isLoading,
          onSelect: { book in presentBookDetail(for: book) }
        )
        .refreshable { model.reloadData() }
      }
    }
  }

  private func presentBookDetail(for book: TPPBook) {
    coordinator.store(book: book)
    coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
  }

  private var searchBar: some View {
    HStack {
      TextField(DisplayStrings.searchBooks, text: $model.searchQuery)
        .searchBarStyle()
        .onChange(of: model.searchQuery) { query in
          Task {
            await model.filterBooks(query: query)
          }
        }
      Button(action: clearSearch, label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.gray)
      })
    }
    .padding(.horizontal)
  }

  private func clearSearch() {
    Task {
      model.searchQuery = ""
      await model.filterBooks(query: "")
    }
  }

  private var loadingOverlay: some View {
    ProgressView()
      .scaleEffect(2)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.opacity(0.5).ignoresSafeArea())
  }

  private var leadingBarButton: some View {
    Button(action: { model.selectNewLibrary.toggle() }) {
      ImageProviders.MyBooksView.myLibraryIcon
    }
    .actionSheet(isPresented: $model.selectNewLibrary) { libraryPicker }
  }

  private var trailingBarButton: some View {
    Button(action: { withAnimation { model.showSearchSheet.toggle() } }) {
      ImageProviders.MyBooksView.search
    }
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
    TPPSettings.shared.settingsAccountsList.map { account in
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
    Text(DisplayStrings.emptyViewMessage)
      .multilineTextAlignment(.center)
      .foregroundColor(.gray)
      .centered()
      .palaceFont(.body)
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
