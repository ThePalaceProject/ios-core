import SwiftUI

struct CatalogView: View {
  @StateObject private var viewModel: CatalogViewModel

  init(viewModel: CatalogViewModel) {
    _viewModel = StateObject(wrappedValue: viewModel)
  }

  var body: some View {
    NavigationView {
      content
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .principal) {
            Button(action: { openLibraryHome() }) {
              HStack(spacing: 8) {
                if let logo = AccountsManager.shared.currentAccount?.logo {
                  Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                }
                Text(AccountsManager.shared.currentAccount?.name ?? (viewModel.title.isEmpty ? "Catalog" : viewModel.title))
                  .font(.headline)
              }
            }
            .buttonStyle(.plain)
          }
          ToolbarItem(placement: .navigationBarLeading) {
            Button(action: { presentAccountPicker() }) {
              ImageProviders.MyBooksView.myLibraryIcon
            }
          }
          ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { presentSearch() }) {
              ImageProviders.MyBooksView.search
            }
          }
        }
        .toolbar {
          // remove duplicate toolbar; keep only the principal/leading/trailing defined above
        }
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

  func presentSearch() {
    let searchVC = TPPCatalogSearchViewController(openSearchDescription: nil)
    TPPRootTabBarController.shared().pushViewController(searchVC, animated: true)
  }

  func openLibraryHome() {
    if let urlString = AccountsManager.shared.currentAccount?.homePageUrl, let url = URL(string: urlString) {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
  }

  func presentAccountPicker() {
    let vc = TPPAccountList { account in
      // minimal behavior: switch account via MyBooks pattern
      AccountsManager.shared.currentAccount = account
    }
    TPPRootTabBarController.shared().safelyPresentViewController(vc, animated: true, completion: nil)
  }
}


