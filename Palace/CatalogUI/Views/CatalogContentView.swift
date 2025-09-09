import SwiftUI

// MARK: - CatalogContentView
struct CatalogContentView: View {
  @ObservedObject var viewModel: CatalogViewModel
  let onBookSelected: (TPPBook) -> Void
  let onLaneMoreTapped: (String, URL) -> Void
  
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      selectorsView
      
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
          SwiftUI.Group {
            contentArea
              .padding(.vertical, 17)
          }
        }
        .padding(.vertical, 17)
        .padding(.bottom, 100)
      }
      .refreshable { await viewModel.refresh() }
    }
  }
}

// MARK: - Private Views
private extension CatalogContentView {
  @ViewBuilder
  var selectorsView: some View {
    if !viewModel.entryPoints.isEmpty {
      EntryPointsSelectorView(entryPoints: viewModel.entryPoints) { facet in
        Task { await viewModel.applyEntryPoint(facet) }
      }
    }

    if !viewModel.facetGroups.isEmpty {
      FacetsSelectorView(facetGroups: viewModel.facetGroups) { facet in
        Task { await viewModel.applyFacet(facet) }
      }
    }
  }

  @ViewBuilder
  var contentArea: some View {
    if viewModel.isContentReloading {
      CatalogLoadingView()
    } else if !viewModel.lanes.isEmpty {
      LazyVStack(alignment: .leading, spacing: 24) {
        ForEach(viewModel.lanes) { lane in
          CatalogLaneRowView(
            title: lane.title,
            books: lane.books.map { TPPBookRegistry.shared.updatedBookMetadata($0) ?? $0 },
            moreURL: lane.moreURL,
            onSelect: onBookSelected,
            showHeader: true
          )
        }
      }
    } else {
      BookListView(
        books: viewModel.ungroupedBooks,
        isLoading: .constant(false),
        onSelect: onBookSelected
      )
    }
  }
}

// MARK: - CatalogLoadingView
struct CatalogLoadingView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      ForEach(0..<3, id: \.self) { _ in
        CatalogLaneSkeletonView()
      }
    }
    .padding(.vertical, 0)
  }
}

