import SwiftUI
import Combine

/// Refactored, streamlined catalog lane view that delegates business logic to ViewModel
struct CatalogLaneMoreView: View {
  
  // MARK: - Properties
  
  @StateObject private var viewModel: CatalogLaneMoreViewModel
  @EnvironmentObject private var coordinator: NavigationCoordinator
  
  // MARK: - Account & Logo State
  
  @StateObject private var logoObserver = CatalogLogoObserver()
  @State private var currentAccountUUID: String = AccountsManager.shared.currentAccount?.uuid ?? ""
  
  // MARK: - Initialization
  
  init(title: String = "", url: URL) {
    _viewModel = StateObject(wrappedValue: CatalogLaneMoreViewModel(title: title, url: url))
  }
  
  // MARK: - Main View
  
  var body: some View {
    VStack(spacing: 0) {
      toolbarSection
      contentSection
    }
    .overlay(alignment: .bottom) { SamplePreviewBarView() }
    .navigationTitle(viewModel.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        LibraryNavTitleView(onTap: { openLibraryHome() })
          .id(logoObserver.token.uuidString + currentAccountUUID)
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        if viewModel.showSearch {
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
    .task { await viewModel.load(coordinator: coordinator) }
    .onAppear {
      Log.debug(#file, "🟢 CatalogLaneMoreView.onAppear() - Appearing")
      setupCoordinator()
      setupAccount()
    }
    .onReceive(accountChangePublisher) { _ in
      handleAccountChange()
    }
    .onReceive(sampleTogglePublisher) { note in
      handleSampleToggle(note)
    }
    .onDisappear {
      Log.debug(#file, "🔴 CatalogLaneMoreView.onDisappear() - Being dismissed")
      SamplePreviewManager.shared.close()
    }
    .onReceive(registryChangePublisher) { note in
      let changedId = (note.userInfo as? [String: Any])?["bookIdentifier"] as? String
      viewModel.applyRegistryUpdates(changedIdentifier: changedId)
    }
    .onReceive(downloadProgressPublisher) { changedId in
      viewModel.applyRegistryUpdates(changedIdentifier: changedId)
    }
    .sheet(isPresented: $viewModel.showingSortSheet) {
      SortOptionsSheet
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $viewModel.showingFiltersSheet) {
      FiltersSheetWrapper
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
  }
  
  // MARK: - Publishers
  
  private var accountChangePublisher: AnyPublisher<Notification, Never> {
    NotificationCenter.default
      .publisher(for: .TPPCurrentAccountDidChange)
      .eraseToAnyPublisher()
  }
  
  private var sampleTogglePublisher: AnyPublisher<Notification, Never> {
    NotificationCenter.default
      .publisher(for: Notification.Name("ToggleSampleNotification"))
      .receive(on: RunLoop.main)
      .eraseToAnyPublisher()
  }
  
  private var registryChangePublisher: AnyPublisher<Notification, Never> {
    NotificationCenter.default
      .publisher(for: .TPPBookRegistryStateDidChange)
      .throttle(for: .milliseconds(350), scheduler: DispatchQueue.main, latest: true)
      .eraseToAnyPublisher()
  }
  
  private var downloadProgressPublisher: AnyPublisher<String, Never> {
    MyBooksDownloadCenter.shared.downloadProgressPublisher
      .throttle(for: .milliseconds(350), scheduler: DispatchQueue.main, latest: true)
      .map { $0.0 }
      .removeDuplicates()
      .eraseToAnyPublisher()
  }
  
  // MARK: - Setup Helpers
  
  private func setupCoordinator() {
    if NavigationCoordinatorHub.shared.coordinator == nil {
      NavigationCoordinatorHub.shared.coordinator = coordinator
    }
  }
  
  private func setupAccount() {
    let account = AccountsManager.shared.currentAccount
    account?.logoDelegate = logoObserver
    account?.loadLogo()
    currentAccountUUID = account?.uuid ?? ""
  }
  
  private func handleAccountChange() {
    if viewModel.showSearch {
      dismissSearch()
    }
    
    setupAccount()
    viewModel.appliedSelections.removeAll()
    viewModel.pendingSelections.removeAll()
    Task { await viewModel.load(coordinator: coordinator) }
  }
  
  private func handleSampleToggle(_ note: Notification) {
    guard let info = note.userInfo as? [String: Any],
          let identifier = info["bookIdentifier"] as? String else { return }
    
    let action = (info["action"] as? String) ?? "toggle"
    if action == "close" {
      SamplePreviewManager.shared.close()
      return
    }
    
    if let book = TPPBookRegistry.shared.book(forIdentifier: identifier) ?? viewModel.allBooks.first(where: { $0.identifier == identifier }) {
      SamplePreviewManager.shared.toggle(for: book)
    }
  }
  
  // MARK: - Navigation
  
  private func presentBookDetail(_ book: TPPBook) {
    setupCoordinator()
    coordinator.store(book: book)
    coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
  }
  
  private func presentLaneMore(title: String, url: URL) {
    setupCoordinator()
    coordinator.push(.catalogLaneMore(title: title, url: url))
  }
  
  private func openLibraryHome() {
    if let urlString = AccountsManager.shared.currentAccount?.homePageUrl,
       let url = URL(string: urlString) {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
  }
  
  // MARK: - Search
  
  private func presentSearch() {
    withAnimation { viewModel.showSearch = true }
  }
  
  private func dismissSearch() {
    withAnimation { viewModel.showSearch = false }
  }
  
  // MARK: - Filter Sheet
  
  private var FiltersSheetWrapper: some View {
    CatalogFiltersSheetView(
      facetGroups: viewModel.facetGroups,
      selection: $viewModel.pendingSelections,
      onApply: { Task { await viewModel.applySingleFilters(coordinator: coordinator) } },
      onCancel: { viewModel.showingFiltersSheet = false },
      isApplying: viewModel.isApplyingFilters
    )
  }
  
  // MARK: - Sort Options Sheet
  
  private var SortOptionsSheet: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(Strings.Catalog.sortBy)
        .font(.headline)
        .padding(.horizontal)
        .padding(.top, 12)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(viewModel.sortFacets, id: \.id) { facet in
            Button(action: { 
              Task {
                await viewModel.applyOPDSFacet(facet, coordinator: coordinator)
                viewModel.showingSortSheet = false
              }
            }) {
              HStack {
                Image(systemName: facet.active ? "largecircle.fill.circle" : "circle")
                  .foregroundColor(.primary)
                Text(facet.title)
                  .foregroundColor(.primary)
                Spacer()
              }
              .padding(.vertical, 12)
              .padding(.horizontal)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .background(Color(UIColor.systemBackground))
    }
  }
  
  // MARK: - Search Section
  
  @ViewBuilder
  private var searchSection: some View {
    CatalogSearchView(
      repository: CatalogRepository(
        api: DefaultCatalogAPI(
          client: URLSessionNetworkClient(),
          parser: OPDSParser()
        )
      ),
      baseURL: { viewModel.url },
      books: viewModel.allBooks,
      onBookSelected: presentBookDetail
    )
  }
}

// MARK: - View Sections

private extension CatalogLaneMoreView {
  
  @ViewBuilder
  var toolbarSection: some View {
    if viewModel.showSearch {
      searchToolbar
    } else if !viewModel.facetGroups.isEmpty {
      filterToolbar
    }
  }
  
  @ViewBuilder
  var searchToolbar: some View {
    EmptyView()
  }
  
  @ViewBuilder
  var filterToolbar: some View {
    FacetToolbarView(
      title: viewModel.title,
      showFilter: true,
      onSort: viewModel.sortFacets.isEmpty ? nil : { viewModel.showingSortSheet = true },
      onFilter: { viewModel.showingFiltersSheet = true },
      currentSortTitle: viewModel.activeSortTitle,
      appliedFiltersCount: viewModel.activeFiltersCount
    )
    .padding(.bottom, 5)
    .overlay(alignment: .trailing) {
      if viewModel.isLoading || viewModel.isApplyingFilters {
        loadingIndicator
      }
    }
    
    Divider()
  }
  
  @ViewBuilder
  var loadingIndicator: some View {
    HStack(spacing: 6) {
      ProgressView()
        .progressViewStyle(CircularProgressViewStyle(tint: .primary))
        .scaleEffect(0.8)
      if viewModel.isApplyingFilters {
        Text("Filtering...")
          .palaceFont(size: 12)
          .foregroundColor(.secondary)
      }
    }
    .padding(.trailing, 12)
  }
  
  @ViewBuilder
  var contentSection: some View {
    if viewModel.showSearch {
      searchSection
    } else if viewModel.isLoading {
      loadingView
    } else if let error = viewModel.error {
      errorView(error)
    } else if !viewModel.lanes.isEmpty {
      lanesView
    } else {
      booksView
    }
  }
  
  @ViewBuilder
  var loadingView: some View {
    ScrollView {
      BookListSkeletonView()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  func errorView(_ errorMessage: String) -> some View {
    Text(errorMessage)
      .padding()
  }
  
  @ViewBuilder
  var lanesView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        ForEach(viewModel.lanes) { lane in
          CatalogLaneRowView(
            title: lane.title,
            books: lane.books,
            moreURL: lane.moreURL,
            onSelect: presentBookDetail,
            onMoreTapped: { title, url in
              presentLaneMore(title: title, url: url)
            },
            showHeader: true
          )
        }
      }
      .padding(.vertical, 12)
    }
    .refreshable {
      await viewModel.fetchAndApplyFeed(at: viewModel.url, clearFilters: false)
    }
  }
  
  @ViewBuilder
  var booksView: some View {
    ScrollView {
      BookListView(
        books: viewModel.ungroupedBooks,
        isLoading: $viewModel.isLoading,
        onSelect: { book in presentBookDetail(book) },
        onLoadMore: viewModel.shouldShowPagination ? { @MainActor in await viewModel.loadNextPage() } : nil,
        isLoadingMore: viewModel.isLoadingMore
      )
    }
    .refreshable {
      await viewModel.fetchAndApplyFeed(at: viewModel.url, clearFilters: false)
    }
  }
}
