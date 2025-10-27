import SwiftUI
import UIKit

struct CatalogView: View {
  // MARK: - Properties
  @EnvironmentObject private var coordinator: NavigationCoordinator
  @StateObject private var viewModel: CatalogViewModel
  @StateObject private var logoObserver = CatalogLogoObserver()
  @State private var currentAccountUUID: String = AccountsManager.shared.currentAccount?.uuid ?? ""
  @State private var showAccountDialog: Bool = false
  @State private var showAddLibrarySheet: Bool = false
  @State private var showSearch: Bool = false

  // MARK: - Initialization
  init(viewModel: CatalogViewModel) {
    _viewModel = StateObject(wrappedValue: viewModel)
  }

  // MARK: - Body
  var body: some View {
    content
      .padding(.top)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(.visible, for: .navigationBar)
      .toolbar { toolbarContent }
      .onAppear { 
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
    }
    ToolbarItem(placement: .navigationBarLeading) {
      Button(action: { showAccountDialog = true }) {
        ImageProviders.MyBooksView.myLibraryIcon
      }
      .actionSheet(isPresented: $showAccountDialog) { libraryPicker }
    }
    
    ToolbarItem(placement: .navigationBarTrailing) {
      if showSearch {
        Button(action: { dismissSearch() }) {
          Text(Strings.Generic.cancel)
        }
      } else {
        Button(action: { presentSearch() }) {
          ImageProviders.MyBooksView.search
        }
      }
    }
  }
  
  private var libraryPicker: ActionSheet {
    var buttons: [ActionSheet.Button] = TPPSettings.shared.settingsAccountsList.map { account in
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
      searchSection
      loadingSection
      errorSection
      mainCatalogSection
    }
  }


  @ViewBuilder
  private var searchSection: some View {
    if showSearch {
      CatalogSearchView(
        repository: viewModel.searchRepository,
        baseURL: viewModel.searchBaseURL,
        books: allBooks,
        onBookSelected: presentBookDetail
      )
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private var loadingSection: some View {
    if !showSearch && viewModel.isLoading {
      skeletonList
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private var errorSection: some View {
    if !showSearch, let error = viewModel.errorMessage {
      Text(error)
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private var mainCatalogSection: some View {
    if !showSearch && !viewModel.isLoading && viewModel.errorMessage == nil {
      CatalogContentView(
        viewModel: viewModel,
        onBookSelected: presentBookDetail,
        onLaneMoreTapped: { title, url in
          coordinator.push(.catalogLaneMore(title: title, url: url))
        }
      )
    } else {
      EmptyView()
    }
  }
  
  func presentBookDetail(_ book: TPPBook) {
    coordinator.store(book: book)
    coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
  }

  func openLibraryHome() {
    if let urlString = AccountsManager.shared.currentAccount?.homePageUrl, let url = URL(string: urlString) {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
  }

  func presentSearch() {
    withAnimation { showSearch = true }
  }
  
  func dismissSearch() {
    withAnimation { 
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
    let account = AccountsManager.shared.currentAccount
    account?.logoDelegate = logoObserver
    account?.loadLogo()
    currentAccountUUID = account?.uuid ?? ""
  }
  
  func handleAccountChange() {
    if showSearch {
      dismissSearch()
    }
    
    let account = AccountsManager.shared.currentAccount
    account?.logoDelegate = logoObserver
    account?.loadLogo()
    currentAccountUUID = account?.uuid ?? ""
    
    coordinator.clearAllCatalogFilterStates()
    
    Task { await viewModel.handleAccountChange() }
  }
  
  func switchToAccount(_ account: Account) {
    if let urlString = account.catalogUrl, let url = URL(string: urlString) {
      TPPSettings.shared.accountMainFeedURL = url
    }
    AccountsManager.shared.currentAccount = account
    
    account.loadAuthenticationDocument { _ in }
    
    NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
    Task { await viewModel.refresh() }
  }
  
  func addAndSwitchToAccount(_ account: Account) {
    if !TPPSettings.shared.settingsAccountIdsList.contains(account.uuid) {
      TPPSettings.shared.settingsAccountIdsList.append(account.uuid)
    }
    switchToAccount(account)
  }
  
  // MARK: - Computed Properties
  var allBooks: [TPPBook] {
    if !viewModel.lanes.isEmpty {
      return viewModel.lanes.flatMap { $0.books }
    }
    return viewModel.ungroupedBooks
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
      .padding(.vertical, 12)
      .padding(.horizontal, 12)
    }
  }
}
