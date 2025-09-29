import PalaceAudiobookToolkit
import SwiftUI

/// Generic host that provides a NavigationStack and a NavigationCoordinator environment object.
struct NavigationHostView<Content: View>: View {
  @StateObject private var coordinator = NavigationCoordinator()
  let rootView: Content

  init(rootView: Content) {
    self.rootView = rootView
  }

  var body: some View {
    NavigationStack(path: $coordinator.path) {
      rootView
        .onAppear { NavigationCoordinatorHub.shared.coordinator = coordinator }
        .navigationDestination(for: AppRoute.self) { route in
          switch route {
          case let .bookDetail(bookRoute):
            if let book = coordinator.resolveBook(for: bookRoute) {
              BookDetailView(book: book)
                .environmentObject(coordinator)
            } else {
              Text("Missing book")
            }
          case let .catalogLaneMore(title, url):
            CatalogLaneMoreView(title: title, url: url)
              .environmentObject(coordinator)
          case let .search(searchRoute):
            CatalogSearchView(
              books: coordinator.resolveSearchBooks(for: searchRoute),
              onBookSelected: { book in
                coordinator.store(book: book)
                coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
              }
            )
          case let .pdf(bookRoute):
            if let (document, metadata) = coordinator.resolvePDF(for: bookRoute) {
              TPPPDFReaderView(document: document)
                .environmentObject(metadata)
            } else {
              EmptyView()
            }
          case let .epub(bookRoute):
            if let vc = coordinator.resolveEPUBController(for: bookRoute) {
              UIViewControllerWrapper(vc, updater: { _ in })
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            } else {
              EmptyView()
            }
          case let .audio(bookRoute):
            if let model = coordinator.resolveAudioModel(for: bookRoute) {
              AudiobookPlayerView(model: model)
            } else if let vc = coordinator.resolveAudioController(for: bookRoute) {
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
  }
}
