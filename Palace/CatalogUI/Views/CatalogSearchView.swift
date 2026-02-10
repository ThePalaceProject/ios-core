import SwiftUI
import Combine

// MARK: - SearchView
struct CatalogSearchView: View {
  @StateObject private var viewModel: CatalogSearchViewModel
  @FocusState private var isSearchFieldFocused: Bool
  let books: [TPPBook]
  let onBookSelected: (TPPBook) -> Void
  
  init(
    repository: CatalogRepositoryProtocol,
    baseURL: @escaping () -> URL?,
    books: [TPPBook],
    onBookSelected: @escaping (TPPBook) -> Void
  ) {
    self._viewModel = StateObject(wrappedValue: CatalogSearchViewModel(repository: repository, baseURL: baseURL))
    self.books = books
    self.onBookSelected = onBookSelected
  }
  
  init(
    books: [TPPBook],
    onBookSelected: @escaping (TPPBook) -> Void
  ) {

    let client = URLSessionNetworkClient()
    let parser = OPDSParser()
    let api = DefaultCatalogAPI(client: client, parser: parser)
    let dummyRepository = CatalogRepository(api: api)
    self._viewModel = StateObject(wrappedValue: CatalogSearchViewModel(repository: dummyRepository, baseURL: { nil }))
    self.books = books
    self.onBookSelected = onBookSelected
  }
  
  var body: some View {
    VStack(spacing: 0) {
      searchBar
      
      ScrollViewReader { proxy in
        ScrollView {
          BookListView(
            books: viewModel.filteredBooks,
            isLoading: $viewModel.isLoading,
            onSelect: onBookSelected,
            onLoadMore: { @MainActor in await viewModel.loadNextPage() },
            isLoadingMore: viewModel.isLoadingMore,
            previewEnabled: false
          )
          .id("search-results-top")
        }
        .scrollDismissesKeyboard(.immediately)
        .onTapGesture {
          isSearchFieldFocused = false
        }
        .onChange(of: viewModel.searchId) { _ in
          // Scroll to top only for new searches, not pagination
          proxy.scrollTo("search-results-top", anchor: .top)
        }
      }
    }
    .onAppear {
      viewModel.updateBooks(books)
    }
    .onChange(of: books) { newBooks in
      viewModel.updateBooks(newBooks)
    }
    .onReceive(registryChangePublisher) { note in
      let changedId = (note.userInfo as? [String: Any])?["bookIdentifier"] as? String
      viewModel.applyRegistryUpdates(changedIdentifier: changedId)
    }
    .onReceive(downloadProgressPublisher) { changedId in
      viewModel.applyRegistryUpdates(changedIdentifier: changedId)
    }
  }
  
  // MARK: - Publishers
  
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
}

// MARK: - Private Views
private extension CatalogSearchView {
  var searchBar: some View {
    ZStack {
      TextField(
        NSLocalizedString("Search Catalog", comment: ""),
        text: Binding(
          get: { viewModel.searchQuery },
          set: { viewModel.updateSearchQuery($0) }
        )
      )
      .accessibilityIdentifier(AccessibilityID.Search.searchField)
      .focused($isSearchFieldFocused)
      .submitLabel(.search)
      .padding(8)
      .padding(.trailing, 40)
      .background(Color.gray.opacity(0.2))
      .cornerRadius(10)
      .padding(.horizontal)
      
      HStack {
        Spacer()
        
        if viewModel.isLoading {
          ProgressView()
            .padding(.trailing, 8)
        } else if !viewModel.searchQuery.isEmpty {
          Button(action: { viewModel.clearSearch() }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.gray)
          }
          .accessibilityLabel(Strings.Generic.clearSearch)
          .padding(.trailing, 8)
        }
      }
      .padding(.horizontal)
    }
    .padding(.vertical, 8)
  }
}
