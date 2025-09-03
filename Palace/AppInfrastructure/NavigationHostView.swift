import SwiftUI
import PalaceAudiobookToolkit

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
        .environmentObject(coordinator)
        .onAppear { NavigationCoordinatorHub.shared.coordinator = coordinator }
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
          case .search(let searchRoute):
            CatalogSearchView(books: coordinator.resolveSearchBooks(for: searchRoute))
          case .pdf(let bookRoute):
            if let (document, metadata) = coordinator.resolvePDF(for: bookRoute) {
              TPPPDFReaderView(document: document)
                .environmentObject(metadata)
            } else {
              EmptyView()
            }
          case .epub(let bookRoute):
            if let vc = coordinator.resolveEPUBController(for: bookRoute) {
              UIViewControllerWrapper(vc, updater: { _ in })
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            } else {
              EmptyView()
            }
          case .audio(let bookRoute):
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
  }
}


