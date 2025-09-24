import SwiftUI

// MARK: - CatalogContentView
struct CatalogContentView: View {
  @ObservedObject var viewModel: CatalogViewModel
  let onBookSelected: (TPPBook) -> Void
  let onLaneMoreTapped: (String, URL) -> Void
  
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      selectorsView
      
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 24) {
            SwiftUI.Group {
              contentArea
                .padding(.vertical, 17)
                .id("catalog-content-top")
            }
          }
          .padding(.vertical, 17)
          .padding(.bottom, 100)
        }
        .refreshable { await viewModel.refresh() }
        .onReceive(viewModel.$shouldScrollToTop) { shouldScroll in
          if shouldScroll {
            withAnimation(.easeInOut(duration: 0.3)) {
              proxy.scrollTo("catalog-content-top", anchor: .top)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
              viewModel.resetScrollTrigger()
            }
          }
        }
      }
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
            onMoreTapped: onLaneMoreTapped,
            showHeader: true,
            isLoading: lane.isLoading || viewModel.isOptimisticLoading
          )
        }
      }
      .opacity(viewModel.isOptimisticLoading ? 0.6 : 1.0)
      .animation(.easeInOut(duration: 0.2), value: viewModel.isOptimisticLoading)
    } else {
      ScrollView {
        BookListView(
          books: viewModel.ungroupedBooks,
          isLoading: .constant(viewModel.isOptimisticLoading),
          onSelect: onBookSelected
        )
      }
      .opacity(viewModel.isOptimisticLoading ? 0.6 : 1.0)
      .animation(.easeInOut(duration: 0.2), value: viewModel.isOptimisticLoading)
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

