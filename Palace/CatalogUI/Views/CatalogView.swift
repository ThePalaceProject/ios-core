import SwiftUI
import UIKit

struct CatalogView: View {
  @StateObject private var viewModel: CatalogViewModel
  @StateObject private var logoObserver = CatalogLogoObserver()
  @State private var currentAccountUUID: String = AccountsManager.shared.currentAccount?.uuid ?? ""

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
          Button(action: { presentAccountPicker() }) {
            ImageProviders.MyBooksView.myLibraryIcon
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: { presentSearch() }) {
            ImageProviders.MyBooksView.search
          }
        }
      }
      .onAppear {
        let account = AccountsManager.shared.currentAccount
        account?.logoDelegate = logoObserver
        account?.loadLogo()
        currentAccountUUID = account?.uuid ?? ""
      }
      .task { await viewModel.load() }
      .onReceive(NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)) { _ in
        let account = AccountsManager.shared.currentAccount
        account?.logoDelegate = logoObserver
        account?.loadLogo()
        currentAccountUUID = account?.uuid ?? ""
        Task { await viewModel.handleAccountChange() }
      }
  }
}

private extension CatalogView {
  @ViewBuilder
  var content: some View {
    if viewModel.isLoading {
      skeletonList
    } else if let error = viewModel.errorMessage {
      Text(error)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          selectorsView
          contentArea
        }
        .padding(.vertical, 12)
      }
      .refreshable { await viewModel.refresh() }
    }
  }
  
  func presentBookDetail(_ book: TPPBook) {
    let detailVC = BookDetailHostingController(book: book)
    TPPRootTabBarController.shared().pushViewController(detailVC, animated: true)
  }

  func openLibraryHome() {
    if let urlString = AccountsManager.shared.currentAccount?.homePageUrl, let url = URL(string: urlString) {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
  }

  func presentSearch() {
    let books: [TPPBook] = !viewModel.lanes.isEmpty ? viewModel.lanes.flatMap { $0.books } : viewModel.ungroupedBooks
    let swiftUIView = CatalogSearchView(books: books)
    let hosting = UIHostingController(rootView: swiftUIView)
    hosting.navigationItem.titleView = LibraryNavTitleFactory.makeTitleView()
    let nav = UINavigationController(rootViewController: hosting)
    TPPRootTabBarController.shared().safelyPresentViewController(nav, animated: true, completion: nil)
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
          TPPRootTabBarController.shared().dismiss(animated: true, completion: nil)
        },
        updater: { _ in }
      )
      let hosting = UIHostingController(rootView: wrapper)
      let nav = UINavigationController(rootViewController: hosting)
      TPPRootTabBarController.shared().safelyPresentViewController(nav, animated: true, completion: nil)
    }
    actionSheet.addAction(addLibrary)
    actionSheet.addAction(UIAlertAction(title: Strings.Generic.cancel, style: .cancel, handler: nil))
    TPPRootTabBarController.shared().safelyPresentViewController(actionSheet, animated: true, completion: nil)
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
      .padding(.horizontal, 8)
    }
  }

  /// Entry point and facet selectors rendered above the content area.
  @ViewBuilder
  var selectorsView: some View {
    if !viewModel.entryPoints.isEmpty {
      EntryPointsSelectorView(entryPoints: viewModel.entryPoints) { facet in
        Task { await viewModel.applyEntryPoint(facet) }
      }
    }

    if !viewModel.facetGroups.isEmpty {
      FacetsSelectorView(facetGroups: viewModel.facetGroups) { facet in
        Task { await viewModel.applyFacet(facet) }
      }
    }
  }

  /// Content area below selectors: shows skeletons while reloading, otherwise lanes or ungrouped list.
  @ViewBuilder
  var contentArea: some View {
    if viewModel.isContentReloading {
      VStack(alignment: .leading, spacing: 24) {
        ForEach(0..<3, id: \.self) { _ in
          CatalogLaneSkeletonView()
        }
      }
      .padding(.vertical, 0)
    } else if !viewModel.lanes.isEmpty {
      LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
        ForEach(viewModel.lanes) { lane in
          Section(
            header:
              HStack {
                Text(lane.title).font(.title3).bold()
                Spacer()
                if let more = lane.moreURL {
                  NavigationLink("More…", destination: CatalogLaneMoreView(title: lane.title, url: more))
                }
              }
              .padding(.horizontal, 12)
              .background(Color(UIColor.systemBackground))
          ) {
            ScrollView(.horizontal, showsIndicators: false) {
              LazyHStack(spacing: 12) {
                ForEach(lane.books, id: \.identifier) { book in
                  Button(action: { presentBookDetail(book) }) {
                    BookImageView(book: book, width: nil, height: 180, usePulseSkeleton: true)
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


