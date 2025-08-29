import SwiftUI

/// Generic host view providing a NavigationStack and coordinator.
/// Use across tabs to get consistent routing and toolbar behavior.
struct CatalogNavigationHostView<Content: View>: View {
  @StateObject var coordinator = NavigationCoordinator()
  let rootView: Content

  init(rootView: Content) {
    self._coordinator = StateObject(wrappedValue: NavigationCoordinator())
    self.rootView = rootView
  }

  init(catalogView: CatalogView) where Content == CatalogView {
    self._coordinator = StateObject(wrappedValue: NavigationCoordinator())
    self.rootView = catalogView
  }

  var body: some View {
    NavigationStack(path: $coordinator.path) {
      rootView
        .environmentObject(coordinator)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(UIColor.systemBackground), for: .navigationBar)
        .navigationDestination(for: AppRoute.self) { route in
          switch route {
          case .bookDetail(let bookRoute):
            if let book = coordinator.resolveBook(for: bookRoute) {
              BookDetailView(book: book)
            } else {
              Text("Missing book")
            }
          case .catalogLaneMore(let title, let url):
            CatalogLaneMoreView(title: title, url: url)
          case .search(let route):
            CatalogSearchView(books: coordinator.resolveSearchBooks(for: route))
          @unknown default:
            EmptyView()
          }
        }
    }
  }
}


