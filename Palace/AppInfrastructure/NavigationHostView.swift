import SwiftUI
import PalaceAudiobookToolkit

/// Generic host that provides a NavigationStack and a NavigationCoordinator environment object.
struct NavigationHostView<Content: View>: View {
    @StateObject private var coordinator = NavigationCoordinator()
    @Environment(\.appContainer) private var appContainer
    let rootView: Content

    init(rootView: Content) {
        self.rootView = rootView
    }

    var body: some View {
        NavigationStack(path: $coordinator.path) {
            rootView
                .navigationTitle("")
                .onAppear { AppContainer.production().navigationCoordinatorHub.coordinator = coordinator }
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
                           let book = coordinator.resolveBook(for: bookRoute),
                           let httpServer = AppContainer.production().readerService.httpServer {
                            let toc = coordinator.resolveReadiumPDFTableOfContents(for: bookRoute)
                            ZStack {
                                ReadiumPDFReaderView(
                                    publication: publication,
                                    book: book,
                                    httpServer: httpServer,
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
                    @unknown default:
                        EmptyView()
                    }
                }
        }
        .environmentObject(coordinator)
    }
}
