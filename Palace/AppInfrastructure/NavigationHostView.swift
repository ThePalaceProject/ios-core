import SwiftUI
import PalaceAudiobookToolkit

/// Generic host that provides a NavigationStack and a NavigationCoordinator environment object.
struct NavigationHostView<Content: View>: View {
    @StateObject private var coordinator = NavigationCoordinator()
    @Environment(\.appContainer) private var appContainer
    let rootView: Content
    /// The tab that hosts this stack. PP-5022 — registration is keyed by tab so a
    /// stack that appears while its tab is offscreen cannot become the target for
    /// reader pushes. Optional, but deliberately WITHOUT a default: a future
    /// fifth tab that forgot to pass one would silently register as fallback-only
    /// and reinstate the defect, with no compile error and no red test. A host
    /// that genuinely has no tab identity has to say `nil` out loud.
    let tab: AppTab?

    init(rootView: Content, tab: AppTab?) {
        self.rootView = rootView
        self.tab = tab
    }

    var body: some View {
        NavigationStack(path: $coordinator.path) {
            rootView
                .navigationTitle("")
                // Registers through the INJECTED container (its environment default
                // is `AppContainer.production()`, so production is unchanged) —
                // the hub now resolves against a per-container tab router, so a
                // test or preview container must see its own host register.
                .onAppear { appContainer.navigationCoordinatorHub.register(coordinator, for: tab) }
                .fullScreenCover(item: $coordinator.presentedEPUBSample) { epubData in
                    if let book = coordinator.resolveBook(for: BookRoute(id: epubData.bookId)) {
                        // The sample EPUB modal is a reader sub-branch; the
                        // mini-player must hide while it is presented.
                        EPUBReaderView(book: book, publication: epubData.publication, forSample: true)
                            .environmentObject(coordinator)
                            .tracksReaderActive(appContainer.audiobookSessionPresenter)
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
                        CatalogLaneMoreView(title: title, url: url, appContainer: appContainer)
                            .environmentObject(coordinator)
                    case .search(let searchRoute):
                        CatalogSearchView(
                            books: coordinator.resolveSearchBooks(for: searchRoute),
                            onBookSelected: { book in
                                coordinator.store(book: book)
                                coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
                            },
                            appContainer: appContainer
                        )
                    case .pdf(let bookRoute):
                        // `.tracksReaderActive(_:)` goes on each rendered
                        // sub-branch, not the case label (see
                        // IsReaderActiveTrackingModifier); EmptyView needs none.
                        switch coordinator.pdfRouteContent(for: bookRoute) {
                        case .extracting(let book):
                            // LCP PDF still decrypting to disk: show progress
                            // inside the reader route rather than a frozen
                            // book-detail page.
                            ReadiumPDFLoadingView(book: book)
                                .toolbar(.hidden, for: .tabBar)
                                .tracksReaderActive(appContainer.audiobookSessionPresenter)
                        case .reader(let document, let metadata):
                            TPPPDFReaderView(document: document)
                                .environmentObject(metadata)
                                .toolbar(.hidden, for: .tabBar)
                                .tracksReaderActive(appContainer.audiobookSessionPresenter)
                        case .empty:
                            EmptyView()
                        }
                    case .epub(let bookRoute):
                        // `.tracksReaderActive(_:)` per sub-branch, as for PDF.
                        if let pubData = coordinator.resolveEPUBPublication(for: bookRoute),
                           let book = coordinator.resolveBook(for: bookRoute) {
                            EPUBReaderView(book: book, publication: pubData.0, forSample: pubData.1)
                                .environmentObject(coordinator)
                                .tracksReaderActive(appContainer.audiobookSessionPresenter)
                        } else if let vc = coordinator.resolveEPUBController(for: bookRoute) {
                            UIViewControllerWrapper(vc, updater: { _ in })
                                .navigationBarBackButtonHidden(true)
                                .toolbar(.hidden, for: .navigationBar)
                                .toolbar(.hidden, for: .tabBar)
                                .tracksReaderActive(appContainer.audiobookSessionPresenter)
                        } else {
                            EmptyView()
                        }
                    case .audio(let bookRoute):
                        // When `in_app_playback_nav_enabled` is OFF the player
                        // is presented via this pushed route (the original
                        // presentation). When ON, the route is never pushed —
                        // `AudiobookSessionManager.presentSession` drives the
                        // root presenter instead and the chrome renders from
                        // `AppTabHostView`'s persistent full-player overlay.
                        if let model = coordinator.resolveAudioModel(for: bookRoute) {
                            AudiobookPlayerView(model: model)
                                .toolbar(.hidden, for: .tabBar)
                        } else {
                            EmptyView()
                        }
                    case .streamingHTML(let bookRoute):
                        // PP-4161: in-app WKWebView reader. The book payload is
                        // resolved from the coordinator's bookById storage —
                        // BookDetailViewModel.presentStreamingReader stores
                        // before pushing.
                        if let book = coordinator.resolveBook(for: bookRoute) {
                            StreamingReaderView(book: book)
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
