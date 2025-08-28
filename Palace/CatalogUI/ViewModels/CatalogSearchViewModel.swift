import Foundation
import Combine

@MainActor
final class CatalogSearchViewModel: ObservableObject {
  @Published var query: String = ""
  @Published private(set) var isSearching: Bool = false
  @Published private(set) var filteredBooks: [TPPBook] = []

  private let allBooks: [TPPBook]

  init(allBooks: [TPPBook]) {
    self.allBooks = allBooks
    self.filteredBooks = allBooks
  }

  func updateQuery(_ newValue: String) {
    query = newValue
    applyLocalFilter()
  }

  private func applyLocalFilter() {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      filteredBooks = allBooks
      return
    }
    
    let lower = trimmed.lowercased()
    filteredBooks = allBooks.filter { book in
      if book.title.lowercased().contains(lower) { return true }
     
      book.authorNameArray?.map {
        return ($0.lowercased().contains(lower)) != nil
      }
      
      return false
    }
  }
}


