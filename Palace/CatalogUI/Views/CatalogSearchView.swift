import SwiftUI

struct CatalogSearchView: View {
  @EnvironmentObject private var coordinator: NavigationCoordinator
  @StateObject private var viewModel: CatalogSearchViewModel

  init(books: [TPPBook]) {
    _viewModel = StateObject(wrappedValue: CatalogSearchViewModel(allBooks: books))
  }

  var body: some View {
    VStack(spacing: 0) {
      searchBar
      BookListView(books: viewModel.filteredBooks, isLoading: .constant(false)) { book in
        presentBookDetail(book)
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        LibraryNavTitleView()
      }
    }
  }

  private var searchBar: some View {
    HStack {
      TextField(NSLocalizedString("Search Catalog", comment: ""), text: Binding(
        get: { viewModel.query },
        set: { viewModel.updateQuery($0) }
      ))
      .padding(8)
      .background(Color.gray.opacity(0.2))
      .cornerRadius(10)
      .padding(.horizontal)

      if !viewModel.query.isEmpty {
        Button(action: { viewModel.updateQuery("") }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.gray)
        }
        .padding(.trailing)
      }
    }
    .padding(.vertical, 8)
  }

  private func presentBookDetail(_ book: TPPBook) {
    coordinator.store(book: book)
    coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
  }
}


