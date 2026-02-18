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
        .onAppear { NavigationCoordinatorHub.shared.coordinator = coordinator }
        .fullScreenCover(item: $coordinator.presentedEPUBSample) { epubData in
          if let book = coordinator.resolveBook(for: BookRoute(id: epubData.bookId)) {
            EPUBReaderView(book: book, publication: epubData.publication, forSample: true)
              .environmentObject(coordinator)
          }
        }
        .navigationDestination(for: AppRoute.self) { route in
          
          switch route {
          case .bookDetail(let bookRoute):
            if let book = coordinator.resolveBook(for: bookRoute) {
              BookDetailView(book: book)
                .environmentObject(coordinator)
            } else {
              Text("Missing book")
            }
          case .catalogLaneMore(let title, let url):
            CatalogLaneMoreView(title: title, url: url)
              .environmentObject(coordinator)
          case .search(let searchRoute):
            CatalogSearchView(
              books: coordinator.resolveSearchBooks(for: searchRoute),
              onBookSelected: { book in
                coordinator.store(book: book)
                coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
              }
            )
          case .pdf(let bookRoute):
            if let (document, metadata) = coordinator.resolvePDF(for: bookRoute) {
              TPPPDFReaderView(document: document)
                .environmentObject(metadata)
                .toolbar(.hidden, for: .tabBar)
            } else {
              EmptyView()
            }
          case .epub(let bookRoute):
            if let pubData = coordinator.resolveEPUBPublication(for: bookRoute),
               let book = coordinator.resolveBook(for: bookRoute) {
              EPUBReaderView(book: book, publication: pubData.0, forSample: pubData.1)
                .environmentObject(coordinator)
            }
            else if let vc = coordinator.resolveEPUBController(for: bookRoute) {
              UIViewControllerWrapper(vc, updater: { _ in })
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
            } else {
              EmptyView()
            }
          case .audio(let bookRoute):
            if let model = coordinator.resolveAudioModel(for: bookRoute) {
              AudiobookPlayerView(model: model)
                .toolbar(.hidden, for: .tabBar)
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


