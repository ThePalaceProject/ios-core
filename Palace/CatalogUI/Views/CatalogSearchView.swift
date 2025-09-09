import SwiftUI

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
