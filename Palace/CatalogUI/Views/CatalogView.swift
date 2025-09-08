import SwiftUI
import UIKit

struct CatalogView: View {
  @EnvironmentObject private var coordinator: NavigationCoordinator
  @StateObject private var viewModel: CatalogViewModel
  @StateObject private var logoObserver = CatalogLogoObserver()
  @State private var currentAccountUUID: String = AccountsManager.shared.currentAccount?.uuid ?? ""
  @State private var showAccountDialog: Bool = false
  @State private var showAddLibrarySheet: Bool = false
  @State private var showSearch: Bool = false
  @State private var searchQuery: String = ""

  init(viewModel: CatalogViewModel) {
    _viewModel = StateObject(wrappedValue: viewModel)
  }

  var body: some View {
    content
      .padding(.top)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          LibraryNavTitleView(onTap: { openLibraryHome() })
            .id(logoObserver.token.uuidString + currentAccountUUID)
        }
        ToolbarItem(placement: .navigationBarLeading) {
          Button(action: { showAccountDialog = true }) {
            ImageProviders.MyBooksView.myLibraryIcon
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          if showSearch {
            Button(action: { withAnimation { showSearch = false; searchQuery = "" } }) {
              Text(Strings.Generic.cancel)
            }
          } else {
            Button(action: { withAnimation { showSearch = true } }) {
              ImageProviders.MyBooksView.search
            }
          }
        }
      }
      .onAppear {
        let account = AccountsManager.shared.currentAccount
        account?.logoDelegate = logoObserver
        account?.loadLogo()
        currentAccountUUID = account?.uuid ?? ""
      }
      .confirmationDialog(Strings.MyBooksView.findYourLibrary, isPresented: $showAccountDialog, titleVisibility: .visible) {
        ForEach(TPPSettings.shared.settingsAccountsList, id: \.uuid) { account in
          Button(account.name) {
            AccountsManager.shared.currentAccount = account
            if let urlString = account.catalogUrl, let url = URL(string: urlString) {
              TPPSettings.shared.accountMainFeedURL = url
            }
            NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
            Task { await viewModel.refresh() }
          }
        }
        Button(Strings.MyBooksView.addLibrary) { showAddLibrarySheet = true }
        Button(Strings.Generic.cancel, role: .cancel) {}
      }
      .sheet(isPresented: $showAddLibrarySheet) {
        UIViewControllerWrapper(
          TPPAccountList { account in
            if !TPPSettings.shared.settingsAccountIdsList.contains(account.uuid) {
              TPPSettings.shared.settingsAccountIdsList.append(account.uuid)
            }
            AccountsManager.shared.currentAccount = account
            if let urlString = account.catalogUrl, let url = URL(string: urlString) {
              TPPSettings.shared.accountMainFeedURL = url
            }
            NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
            Task { await viewModel.refresh() }
            showAddLibrarySheet = false
          },
          updater: { _ in }
        )
      }
      .task { await viewModel.load() }
      .onReceive(NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)) { _ in
        let account = AccountsManager.shared.currentAccount
        account?.logoDelegate = logoObserver
        account?.loadLogo()
        currentAccountUUID = account?.uuid ?? ""
        Task { await viewModel.handleAccountChange() }
      }
      .onReceive(NotificationCenter.default.publisher(for: .AppTabSelectionDidChange)) { _ in
        if showSearch {
          withAnimation { showSearch = false }
          searchQuery = ""
        }
      }
  }
}

private extension CatalogView {
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
      VStack(spacing: 0) {
        searchBar
        BookListView(books: filteredBooks, isLoading: .constant(false)) { book in
          presentBookDetail(book)
        }
      }
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
      VStack(alignment: .leading, spacing: 0) {
        selectorsView

        ScrollView {
          LazyVStack(alignment: .leading, spacing: 24) {
            SwiftUI.Group {
              contentArea
            }
          }
          .padding(.vertical, 12)
          .padding(.bottom, 100)
        }
        .refreshable { await viewModel.refresh() }
      }
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

  func presentAccountPicker() {
    let actionSheet = UIAlertController(title: Strings.MyBooksView.findYourLibrary, message: nil, preferredStyle: .actionSheet)
    let accounts = TPPSettings.shared.settingsAccountsList
    for account in accounts {
      let action = UIAlertAction(title: account.name, style: .default) { _ in
        AccountsManager.shared.currentAccount = account
        if let urlString = account.catalogUrl, let url = URL(string: urlString) {
          TPPSettings.shared.accountMainFeedURL = url
        }
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        Task { await viewModel.refresh() }
      }
      actionSheet.addAction(action)
    }
    let addLibrary = UIAlertAction(title: Strings.MyBooksView.addLibrary, style: .default) { _ in
      let wrapper = UIViewControllerWrapper(
        TPPAccountList { account in
          if !TPPSettings.shared.settingsAccountIdsList.contains(account.uuid) {
            TPPSettings.shared.settingsAccountIdsList.append(account.uuid)
          }
          AccountsManager.shared.currentAccount = account
          if let urlString = account.catalogUrl, let url = URL(string: urlString) {
            TPPSettings.shared.accountMainFeedURL = url
          }
          NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
          Task { await viewModel.refresh() }
          showAddLibrarySheet = false
        },
        updater: { _ in }
      )
      let hosting = UIHostingController(rootView: wrapper)
      let nav = UINavigationController(rootViewController: hosting)
      if let top = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() {
        top.present(nav, animated: true)
      }
    }
    actionSheet.addAction(addLibrary)
    actionSheet.addAction(UIAlertAction(title: Strings.Generic.cancel, style: .cancel, handler: nil))
    if let top = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() {
      top.present(actionSheet, animated: true)
    }
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

  /// Entry point and facet selectors rendered above the content area.
  @ViewBuilder
  var selectorsView: some View {
    if !showSearch && !viewModel.entryPoints.isEmpty {
      EntryPointsSelectorView(entryPoints: viewModel.entryPoints) { facet in
        Task { await viewModel.applyEntryPoint(facet) }
      }
    }

    if !showSearch && !viewModel.facetGroups.isEmpty {
      FacetsSelectorView(facetGroups: viewModel.facetGroups) { facet in
        Task { await viewModel.applyFacet(facet) }
      }
    }
  }

  @ViewBuilder
  var contentArea: some View {
    if showSearch {
      VStack(spacing: 0) {
        searchBar
        BookListView(books: filteredBooks, isLoading: .constant(false)) { book in
          presentBookDetail(book)
        }
      }
    } else if viewModel.isContentReloading {
      VStack(alignment: .leading, spacing: 24) {
        ForEach(0..<3, id: \.self) { _ in
          CatalogLaneSkeletonView()
        }
      }
      .padding(.vertical, 0)
    } else if !viewModel.lanes.isEmpty {
      LazyVStack(alignment: .leading, spacing: 24) {
        ForEach(viewModel.lanes) { lane in
          Section(
            header:
              HStack(alignment: .top) {
                Text(lane.title)
                  .font(.title2)
                  .lineLimit(3)
                  .multilineTextAlignment(.leading)
                  .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let more = lane.moreURL {
                  Button("More…") {
                    coordinator.push(.catalogLaneMore(title: lane.title, url: more))
                  }
                  .font(.footnote)
                }
              }
              .padding(.horizontal, 12)
              .background(Color(UIColor.systemBackground))
          ) {
            ScrollView(.horizontal, showsIndicators: false) {
              LazyHStack(spacing: 12) {
                ForEach(lane.books, id: \.identifier) { book in
                  Button(action: { presentBookDetail(book) }) {
                    BookImageView(book: book, width: nil, height: 150, usePulseSkeleton: true)
                  }
                  .buttonStyle(.plain)
                }
              }
              .padding(.horizontal, 12)
            }
          }
        }
      }
    } else {
      BookListView(books: viewModel.ungroupedBooks, isLoading: .constant(false)) { book in
        presentBookDetail(book)
      }
    }
  }
}

// MARK: - Search helpers
private extension CatalogView {
  var allBooks: [TPPBook] {
    if !viewModel.lanes.isEmpty {
      return viewModel.lanes.flatMap { $0.books }
    }
    return viewModel.ungroupedBooks
  }

  var filteredBooks: [TPPBook] {
    let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return allBooks }
    let lower = q.lowercased()

    return allBooks.filter { book in
      let title = book.title.lowercased()
      let authors = (book.authors ?? "").lowercased()
      return title.contains(lower) || authors.contains(lower)
    }
  }

  var searchBar: some View {
    ZStack {
      TextField(NSLocalizedString("Search Catalog", comment: ""), text: $searchQuery)
        .padding(8)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(10)
        .padding(.horizontal)
      
      if !searchQuery.isEmpty {
        HStack {
          Spacer()
          Button(action: { searchQuery = "" }) {
            Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
          }
          .padding(.trailing, 20)
        }
      }
    }
    .padding(.vertical, 8)
  }
}


