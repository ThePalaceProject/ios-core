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
                        // §7.3 Option α — sample EPUB modal is a reader
                        // sub-branch; mini-player must suppress while it's
                        // presented. Architect A3 — apply per sub-branch.
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
                            }
                        )
                    case .pdf(let bookRoute):
                        // Readium-backed LCP PDF path takes precedence when a
                        // Publication has been stored for this book. The
                        // loading overlay stays on top of the navigator
                        // until the navigator's first `locationDidChange`
                        // fires — that's the real "page 1 rendered"
                        // signal. Hiding the loader the instant the
                        // publication landed in the coordinator showed
                        // the user a blank navigator while the hundreds
                        // of decrypt calls walked the PDF cross-ref.
                        //
                        // §7.3 Option α + architect A3 — `.tracksReaderActive(_:)`
                        // is applied per-sub-branch (NOT on the case label) so
                        // each rendered PDF view's appearance lifecycle drives
                        // the mini-player suppression flag. EmptyView fallback
                        // does NOT need the modifier (no reader → no
                        // suppression needed).
                        if let (publication, metadata) = coordinator.resolveReadiumPDF(for: bookRoute),
                           let book = coordinator.resolveBook(for: bookRoute) {
                            let toc = coordinator.resolveReadiumPDFTableOfContents(for: bookRoute)
                            ZStack {
                                ReadiumPDFReaderView(
                                    publication: publication,
                                    book: book,
                                    tableOfContents: toc?.toc ?? [],
                                    pageCount: toc?.pageCount ?? 0
                                )
                                    .environmentObject(metadata)

                                if coordinator.isReadiumPDFPending(for: bookRoute) {
                                    ReadiumPDFLoadingView(book: book)
                                        .transition(.opacity)
                                }
                            }
                            .toolbar(.hidden, for: .tabBar)
                            .tracksReaderActive(appContainer.audiobookSessionPresenter)
                        } else if coordinator.isReadiumPDFPending(for: bookRoute),
                                  let book = coordinator.resolveBook(for: bookRoute) {
                            // Publication hasn't landed yet — show a
                            // loader inside the reader nav so the user
                            // knows something's happening rather than
                            // seeing a frozen book-detail page.
                            ReadiumPDFLoadingView(book: book)
                                .toolbar(.hidden, for: .tabBar)
                                .tracksReaderActive(appContainer.audiobookSessionPresenter)
                        } else if let (document, metadata) = coordinator.resolvePDF(for: bookRoute) {
                            TPPPDFReaderView(document: document)
                                .environmentObject(metadata)
                                .toolbar(.hidden, for: .tabBar)
                                .tracksReaderActive(appContainer.audiobookSessionPresenter)
                        } else {
                            EmptyView()
                        }
                    case .epub(let bookRoute):
                        // §7.3 Option α + architect A3 — `.tracksReaderActive(_:)`
                        // is applied per-sub-branch (NOT on the case label)
                        // because each EPUB render path has its own onAppear /
                        // onDisappear lifecycle. EmptyView fallback does not
                        // get the modifier.
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
