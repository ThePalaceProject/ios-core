import SwiftUI

// MARK: - CatalogLaneMoreContentView

struct CatalogLaneMoreContentView: View {
  @ObservedObject var viewModel: CatalogLaneMoreViewModel
  let onBookSelected: (TPPBook) -> Void
  let onLaneMoreTapped: (String, URL) -> Void

  var body: some View {
    if viewModel.isLoading {
      loadingView
    } else if let error = viewModel.error {
      errorView(error)
    } else if !viewModel.lanes.isEmpty {
      lanesView
    } else {
      booksListView
    }
  }
}

// MARK: - Private Views

private extension CatalogLaneMoreContentView {
  var loadingView: some View {
    ScrollView {
      BookListSkeletonView()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  func errorView(_ error: String) -> some View {
    Text(error)
      .padding()
  }

  var lanesView: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        ForEach(viewModel.lanes) { lane in
          CatalogLaneRowView(
            title: lane.title,
            books: lane.books.map { TPPBookRegistry.shared.updatedBookMetadata($0) ?? $0 },
            moreURL: lane.moreURL,
            onSelect: onBookSelected,
            onMoreTapped: onLaneMoreTapped,
            showHeader: true
          )
          .dismissKeyboardOnTap()
        }
      }
      .padding(.vertical, 20)
    }
    .refreshable { await viewModel.refresh() }
  }

  var booksListView: some View {
    ScrollView {
      BookListView(
        books: viewModel.sortedBooks,
        isLoading: .constant(false),
        onSelect: onBookSelected
      )
    }
    .refreshable { await viewModel.refresh() }
  }
}
