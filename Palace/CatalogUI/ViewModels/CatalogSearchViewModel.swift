import Foundation
import Combine

// MARK: - SearchView Model
@MainActor
class CatalogSearchViewModel: ObservableObject {
  @Published var searchQuery: String = ""
  @Published var filteredBooks: [TPPBook] = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String?
  @Published var nextPageURL: URL?
  @Published var isLoadingMore: Bool = false
  
  private var allBooks: [TPPBook] = []
  private let repository: CatalogRepositoryProtocol
  private let baseURL: () -> URL?
  private var searchTask: Task<Void, Never>?
  private var debounceTimer: Timer?
  
  init(repository: CatalogRepositoryProtocol, baseURL: @escaping () -> URL?) {
    self.repository = repository
    self.baseURL = baseURL
  }
  
  deinit {
    debounceTimer?.invalidate()
    searchTask?.cancel()
  }
  
  func updateBooks(_ books: [TPPBook]) {
    allBooks = books
    if searchQuery.isEmpty {
      filteredBooks = books
    }
  }
  
  func updateSearchQuery(_ query: String) {
    searchQuery = query
    
    debounceTimer?.invalidate()
    debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.performSearch()
      }
    }
  }
  
  func clearSearch() {
    searchQuery = ""
    debounceTimer?.invalidate()
    searchTask?.cancel()
    isLoading = false
    errorMessage = nil
    filteredBooks = allBooks
    nextPageURL = nil
    isLoadingMore = false
  }
  
  private func performSearch() {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Cancel any existing search task
    searchTask?.cancel()
    
    guard !query.isEmpty else {
      // Show preloaded books when no search query
      filteredBooks = allBooks
      nextPageURL = nil
      isLoading = false
      return
    }
    
    guard let url = baseURL() else {
      filteredBooks = []
      nextPageURL = nil
      isLoading = false
      return
    }
    
    // Clear pagination for new search
    nextPageURL = nil
    isLoadingMore = false
    isLoading = true
    
    searchTask = Task { [weak self] in
      // Ensure isLoading is cleared on all exit paths
      defer { self?.isLoading = false }
      
      do {
        guard let self, !Task.isCancelled else { return }
        
        let feed = try await self.repository.search(query: query, baseURL: url)
        
        guard !Task.isCancelled else { return }
        
        if let feed = feed {
          // Extract books from search results and map through registry for correct button states
          let feedObjc = feed.opdsFeed
          var searchResults: [TPPBook] = []
          
          if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
            searchResults = opdsEntries.compactMap { CatalogViewModel.makeBook(from: $0) }
          }
          
          self.filteredBooks = searchResults
          self.extractNextPageURL(from: feedObjc)
        } else {
          self.filteredBooks = []
          self.nextPageURL = nil
        }
      } catch {
        guard !Task.isCancelled else { return }
        self?.filteredBooks = []
        self?.nextPageURL = nil
      }
    }
  }
  
  // MARK: - Pagination
  
  private func extractNextPageURL(from feed: TPPOPDSFeed) {
    guard let links = feed.links as? [TPPOPDSLink] else {
      nextPageURL = nil
      return
    }
    
    for link in links {
      if link.rel == "next" {
        nextPageURL = link.href
        return
      }
    }
    
    nextPageURL = nil
  }
  
  func loadNextPage() async {
    guard let nextURL = nextPageURL, !isLoadingMore else { return }
    
    isLoadingMore = true
    defer { isLoadingMore = false }
    
    do {
      guard let feed = try await repository.fetchFeed(at: nextURL) else {
        return
      }
      
      let feedObjc = feed.opdsFeed
      extractNextPageURL(from: feedObjc)
      
      if let entries = feedObjc.entries as? [TPPOPDSEntry] {
        let newBooks = entries.compactMap { CatalogViewModel.makeBook(from: $0) }
        filteredBooks.append(contentsOf: newBooks)
      }
    } catch {
      Log.error(#file, "Failed to load next page of search results: \(error.localizedDescription)")
    }
  }
  
  // MARK: - Registry Sync
  
  /// Refresh visible books with registry state (for downloaded/borrowed books)
  func applyRegistryUpdates(changedIdentifier: String?) {
    guard !filteredBooks.isEmpty else { return }
    
    var books = filteredBooks
    var anyChanged = false
    for idx in books.indices {
      let book = books[idx]
      if let changedIdentifier, book.identifier != changedIdentifier { continue }
      
      // Check if book is in registry
      if let registryBook = TPPBookRegistry.shared.book(forIdentifier: book.identifier) {
        // Book is in registry - use registry version
        books[idx] = registryBook
        anyChanged = true
      } else {
        // Book is NOT in registry (e.g., returned) - invalidate cached model
        // so it gets recreated with fresh state from availability data
        BookCellModelCache.shared.invalidate(for: book.identifier)
        anyChanged = true
      }
    }
    if anyChanged { filteredBooks = books }
  }
}

