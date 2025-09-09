import Foundation
import Combine

// MARK: - SearchView Model
@MainActor
class CatalogSearchViewModel: ObservableObject {
  @Published var searchQuery: String = ""
  @Published var filteredBooks: [TPPBook] = []
  
  private var allBooks: [TPPBook] = []
  
  func updateBooks(_ books: [TPPBook]) {
    allBooks = books
    filterBooks()
  }
  
  func updateSearchQuery(_ query: String) {
    searchQuery = query
    filterBooks()
  }
  
  func clearSearch() {
    searchQuery = ""
    filterBooks()
  }
  
  private func filterBooks() {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      filteredBooks = allBooks
      return
    }
    
    let lowercaseQuery = query.lowercased()
    filteredBooks = allBooks.filter { book in
      let title = book.title.lowercased()
      let authors = (book.authors ?? "").lowercased()
      return title.contains(lowercaseQuery) || authors.contains(lowercaseQuery)
    }
  }
}
