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
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(UIColor.systemBackground), for: .navigationBar)
        .toolbarColorScheme(.automatic, for: .navigationBar)
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
          case .pdf(let bookRoute):
            if let (document, metadata) = coordinator.resolvePDF(for: bookRoute) {
              TPPPDFReaderView(document: document)
                .environmentObject(metadata)
            } else if let vc = coordinator.resolvePDFController(for: bookRoute) {
              UIViewControllerWrapper(vc, updater: { _ in })
            } else {
              EmptyView()
            }
          case .audio(let bookRoute):
            if let model = coordinator.resolveAudioModel(for: bookRoute) {
              AudiobookPlayerView(model: model)
            } else {
              EmptyView()
            }
          case .epub(let bookRoute):
            if let vc = coordinator.resolveEPUBController(for: bookRoute) {
              UIViewControllerWrapper(vc, updater: { _ in })
            } else {
              EmptyView()
            }
          @unknown default:
            EmptyView()
          }
        }
    }
    .environmentObject(coordinator)
    .onAppear { NavigationCoordinatorHub.shared.coordinator = coordinator }
  }
}


