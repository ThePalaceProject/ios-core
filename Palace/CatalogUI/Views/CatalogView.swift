import SwiftUI

struct CatalogView: View {
  @StateObject private var viewModel: CatalogViewModel

  init(viewModel: CatalogViewModel) {
    _viewModel = StateObject(wrappedValue: viewModel)
  }

  var body: some View {
    NavigationView {
      content
        .navigationTitle(viewModel.title.isEmpty ? "Catalog" : viewModel.title)
    }
    .task { await viewModel.load() }
  }
}

private extension CatalogView {
  @ViewBuilder
  var content: some View {
    if viewModel.isLoading {
      ProgressView()
    } else if let error = viewModel.errorMessage {
      Text(error)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          if !viewModel.lanes.isEmpty {
            ForEach(viewModel.lanes) { lane in
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text(lane.title).font(.title3).bold()
                  Spacer()
                  if let more = lane.moreURL {
                    NavigationLink("More…", destination: CatalogLaneMoreView(title: lane.title, url: more))
                  }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                  LazyHStack(spacing: 12) {
                    ForEach(lane.books, id: \.identifier) { book in
                      Button(action: { presentBookDetail(book) }) {
                        BookImageView(book: book, height: 200)
                          .frame(width: 140, height: 200)
                      }
                      .buttonStyle(.plain)
                    }
                  }
                  .padding(.horizontal, 12)
                }
              }
            }
          } else {
            // Ungrouped feed
            BookListView(books: viewModel.ungroupedBooks, isLoading: .constant(false)) { book in
              presentBookDetail(book)
            }
          }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
      }
    }
  }
  
  func presentBookDetail(_ book: TPPBook) {
    let detailVC = BookDetailHostingController(book: book)
    TPPRootTabBarController.shared().pushViewController(detailVC, animated: true)
  }
}


