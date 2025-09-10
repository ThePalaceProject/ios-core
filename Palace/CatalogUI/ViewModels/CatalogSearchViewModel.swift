import Foundation
import Combine

// MARK: - SearchView Model
@MainActor
class CatalogSearchViewModel: ObservableObject {
  @Published var searchQuery: String = ""
  @Published var filteredBooks: [TPPBook] = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String?
  
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
  }
  
  private func performSearch() {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Cancel any existing search task
    searchTask?.cancel()
    
    guard !query.isEmpty else {
      // Show preloaded books when no search query
      filteredBooks = allBooks
      return
    }
    
    guard let url = baseURL() else {
      filteredBooks = []
      return
    }
    
    searchTask = Task { [weak self] in
      do {
        guard let self, !Task.isCancelled else { return }
        
        let feed = try await self.repository.search(query: query, baseURL: url)
        
        guard !Task.isCancelled else { return }
        
        await MainActor.run {
          guard !Task.isCancelled else { return }
          
          if let feed = feed {
            // Extract books from search results
            let feedObjc = feed.opdsFeed
            var searchResults: [TPPBook] = []
            
            if let opdsEntries = feedObjc.entries as? [TPPOPDSEntry] {
              searchResults = opdsEntries.compactMap { CatalogViewModel.makeBook(from: $0) }
            }
            
            self.filteredBooks = searchResults
          } else {
            self.filteredBooks = []
          }
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard !Task.isCancelled else { return }
          self?.filteredBooks = []
        }
      }
    }
  }
  
}
