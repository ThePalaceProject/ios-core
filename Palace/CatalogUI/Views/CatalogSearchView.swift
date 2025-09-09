import SwiftUI

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

// MARK: - SearchView
struct CatalogSearchView: View {
  @StateObject private var viewModel = CatalogSearchViewModel()
  let books: [TPPBook]
  let onBookSelected: (TPPBook) -> Void
  
  var body: some View {
    VStack(spacing: 0) {
      searchBar
      BookListView(
        books: viewModel.filteredBooks,
        isLoading: .constant(false),
        onSelect: onBookSelected
      )
    }
    .onAppear {
      viewModel.updateBooks(books)
    }
    .onChange(of: books) { newBooks in
      viewModel.updateBooks(newBooks)
    }
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
      .padding(8)
      .background(Color.gray.opacity(0.2))
      .cornerRadius(10)
      .padding(.horizontal)
      
      if !viewModel.searchQuery.isEmpty {
        HStack {
          Spacer()
          Button(action: { viewModel.clearSearch() }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.gray)
          }
          .padding(.trailing, 20)
        }
      }
    }
    .padding(.vertical, 8)
  }
}
