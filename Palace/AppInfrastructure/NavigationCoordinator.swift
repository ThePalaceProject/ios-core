import SwiftUI
import UIKit
import PalaceAudiobookToolkit
import ReadiumShared
import PalaceLogging
import PalaceBookModel

/// High-level app routes for SwiftUI NavigationStack.
/// Extend incrementally as new flows migrate to SwiftUI.
enum AppRoute: Hashable {
    case bookDetail(BookRoute)
    case catalogLaneMore(title: String, url: URL)
    case search(SearchRoute)
    case pdf(BookRoute)
    case audio(BookRoute)
    case epub(BookRoute)
    /// PP-4161: in-app WKWebView reader for `text/html;profile=streaming-media`
    /// titles. Pushed (mirrors Reader2/Reader3) rather than sheet-presented
    /// so back-gesture / swipe-down dismiss behaves the same as the other
    /// readers and the route appears in NavigationPath for back-stack support.
    case streamingHTML(BookRoute)
}

/// Lightweight, hashable identifier for a book navigation route.
/// Holds only stable identity for navigation path hashing.
struct BookRoute: Hashable {
    let id: String
}

struct SearchRoute: Hashable {
    let id: UUID
}

struct EPUBPresentationData: Identifiable {
    let id: String
    let bookId: String
    let publication: Publication

    init(bookId: String, publication: Publication) {
        self.id = "\(bookId)-sample-\(UUID().uuidString)"
        self.bookId = bookId
        self.publication = publication
    }
}

/// Weak wrapper for UIViewController to prevent retain cycles
private class WeakViewController {
    weak var viewController: UIViewController?

    init(_ viewController: UIViewController) {
        self.viewController = viewController
    }
}

/// Centralized coordinator for NavigationStack-based routing.
/// Owns a NavigationPath and transient payload storage to resolve non-hashable models.
@MainActor
final class NavigationCoordinator: ObservableObject {
    @Published var path = NavigationPath() {
        didSet {
            // When the user navigates back via SwiftUI's built-in back gesture
            // (bypassing our pop()), isTopRouteAudio becomes stale. Reset it
            // whenever the path shrinks to avoid wrongly clearing the full stack
            // on the next audiobook open.
            if path.count < oldValue.count {
                isTopRouteAudio = false
                // Every way a route leaves (back button, swipe-back, pop to root,
                // a programmatic pop) shrinks the path through this setter.
                backOutLCPPDFRoutesNoLongerOnStack()
            }
        }
    }

    /// Transient payload storage keyed by stable identifiers.
    /// This lets us resolve non-hashable models like Objective-C `TPPBook` at destination time.
    private var bookById: [String: TPPBook] = [:]
    private var searchBooksById: [UUID: [TPPBook]] = [:]

    /// Weak references to prevent retain cycles (deprecated, kept for backward compatibility)
    private var pdfControllerById: [String: WeakViewController] = [:]
    private var epubControllerById: [String: WeakViewController] = [:]

    /// Modern SwiftUI-friendly storage
    private var epubPublicationById: [String: (Publication, Bool)] = [:] // (publication, forSample)

    /// EPUB samples presented as modal fullScreenCover
    @Published var presentedEPUBSample: EPUBPresentationData?

    /// Car Mode fullscreen presentation (feature-flagged)
    @Published var presentCarMode = false

    private var audioModelById: [String: AudiobookPlaybackModel] = [:]
    private var pdfContentById: [String: (TPPPDFDocument, TPPPDFDocumentMetadata)] = [:]
    /// Books whose LCP PDF is still being decrypted to disk. Set when the
    /// `.pdf` route is pushed; cleared when the extracted file reaches PDFKit,
    /// when the open is torn down, or when the route leaves the stack.
    /// `@Published` because `pdfContentById` is not: clearing this flag is what
    /// re-renders the route from the loading view to the reader.
    @Published private var lcpPDFExtractPending: Set<String> = []
    /// Pending LCP PDF routes pushed through `pushLCPPDFExtractRoute`: the path
    /// depth the route sits at, and what to run if it leaves before the extract
    /// completes. Depth rather than identity because `NavigationPath` elements
    /// cannot be read back.
    private var pendingLCPPDFRoutes: [String: (depth: Int, onBackOut: () -> Void)] = [:]
    private var catalogFilterStatesByURL: [String: CatalogLaneFilterState] = [:]

    private let maxStoredItems = 100
    private var cleanupTask: Task<Void, Never>?
    private var lastPopTime: Date?

    /// Tracks whether the top of the navigation stack is an audio route.
    /// Used so we only clear the stack when replacing an existing player (e.g. switching audiobooks),
    /// not when pushing the player from book detail (so "My Books" returns to book detail, not catalog).
    private var isTopRouteAudio: Bool = false

    // MARK: - Public API

    func push(_ route: AppRoute) {
        Log.debug(#file, "📍 NavigationCoordinator.push(\(route)) - Current path count: \(path.count)")
        // Respect reduce motion accessibility setting
        if UIAccessibility.isReduceMotionEnabled {
            path.append(route)
        } else {
            withAnimation(.easeInOut) {
                path.append(route)
            }
        }
        switch route {
        case .audio: isTopRouteAudio = true
        default: isTopRouteAudio = false
        }
        Log.debug(#file, "📍 NavigationCoordinator.push(\(route)) - After push count: \(path.count)")
    }

    func pop() {
        guard !path.isEmpty else {
            Log.debug(#file, "📍 NavigationCoordinator.pop() - Path is empty, ignoring")
            return
        }

        // Prevent double-pop within 200ms (debouncing)
        if let lastPop = lastPopTime, Date().timeIntervalSince(lastPop) < 0.2 {
            Log.warn(#file, "📍 NavigationCoordinator.pop() - Ignoring duplicate pop within 200ms")
            return
        }

        lastPopTime = Date()
        isTopRouteAudio = false
        Log.debug(#file, "📍 NavigationCoordinator.pop() - Current path count: \(path.count)")
        // Respect reduce motion accessibility setting
        if UIAccessibility.isReduceMotionEnabled {
            path.removeLast()
        } else {
            withAnimation(.easeInOut) {
                path.removeLast()
            }
        }
        Log.debug(#file, "📍 NavigationCoordinator.pop() - After pop count: \(path.count)")
    }

    /// Pops ONLY when the audiobook player is actually the top route.
    ///
    /// PP-4542: opening a new audiobook while a previous session is still bound
    /// tears that session down via `stopPlayback(dismissPhoneUI: true)` →
    /// `dismissPlayerOnPhone` → pop. But if the previous player's screen was
    /// already gone (the user navigated back, then opened a different title),
    /// an unconditional `pop()` removes the WRONG thing — the *new* book's
    /// detail — dumping the user onto the catalog. With the download-gate that
    /// gap lasts the entire download. Guarding on `isTopRouteAudio` makes the
    /// teardown a no-op when there's no player on top to dismiss, so the new
    /// book's detail stays put until the real player is pushed.
    func popIfTopRouteAudio() {
        guard isTopRouteAudio else {
            Log.debug(#file, "📍 popIfTopRouteAudio — top route is not the audio player; skipping pop")
            return
        }
        pop()
    }

    /// Pops the entire stack back to the root.
    ///
    /// `animated: false` is for teardown the patron did not ask for — the
    /// account-switch sweep, and being sent to a tab's root by the app while
    /// arriving from another tab, where the tab transition hides the collapse.
    /// A pop the patron can SEE happen animates: re-tapping the tab they are
    /// already on, and being sent to the root of the tab they are already on.
    /// (Until PP-5051 this flag existed for the tab-switch reset, which ran
    /// concurrently with SwiftUI's cross-tab transition and tore; that reset is
    /// gone.)
    func popToRoot(animated: Bool = true) {
        guard !path.isEmpty else { return }
        isTopRouteAudio = false
        // Respect reduce motion accessibility setting
        if !animated || UIAccessibility.isReduceMotionEnabled {
            path.removeLast(path.count)
        } else {
            withAnimation(.easeInOut) {
                path.removeLast(path.count)
            }
        }
    }

    /// Removes all existing audio routes from the navigation path.
    /// Used before pushing a new audio route when the top is already audio (e.g. switching audiobooks).
    func clearAudioRoutes() {
        guard !path.isEmpty else { return }
        isTopRouteAudio = false
        Log.debug(#file, "📍 NavigationCoordinator.clearAudioRoutes() - Clearing path for new audio route")
        // Respect reduce motion accessibility setting
        if UIAccessibility.isReduceMotionEnabled {
            path.removeLast(path.count)
        } else {
            withAnimation(.easeInOut) {
                path.removeLast(path.count)
            }
        }
    }

    /// Pushes an audio route. Clears the stack only when the top is already an audio route
    /// (e.g. switching to another audiobook), so that opening from book detail keeps the stack
    /// and "My Books" in the player returns to book detail instead of catalog (PP-3783).
    func pushAudioRoute(_ route: BookRoute) {
        Log.debug(#file, "📍 NavigationCoordinator.pushAudioRoute(\(route.id)) - Current path count: \(path.count), isTopRouteAudio: \(isTopRouteAudio)")

        if isTopRouteAudio {
            clearAudioRoutes()
        }

        // Push the new audio route (respect reduce motion)
        if UIAccessibility.isReduceMotionEnabled {
            path.append(AppRoute.audio(route))
        } else {
            withAnimation(.easeInOut) {
                path.append(AppRoute.audio(route))
            }
        }
        isTopRouteAudio = true
        Log.debug(#file, "📍 NavigationCoordinator.pushAudioRoute - After push count: \(path.count)")
    }

    func store(book: TPPBook) {
        bookById[book.identifier] = book
        scheduleCleanupIfNeeded()
    }

    private func scheduleCleanupIfNeeded() {
        let totalItems = bookById.count + searchBooksById.count + pdfControllerById.count +
            epubControllerById.count + epubPublicationById.count + audioModelById.count +
            pdfContentById.count + catalogFilterStatesByURL.count

        if totalItems > maxStoredItems {
            cleanupTask?.cancel()
            cleanupTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await MainActor.run {
                    self?.performCleanup()
                }
            }
        }
    }

    private func performCleanup() {
        let keepCount = maxStoredItems / 2

        if bookById.count > keepCount {
            let keysToRemove = Array(bookById.keys.prefix(bookById.count - keepCount))
            keysToRemove.forEach { bookById.removeValue(forKey: $0) }
        }

        if searchBooksById.count > keepCount {
            let keysToRemove = Array(searchBooksById.keys.prefix(searchBooksById.count - keepCount))
            keysToRemove.forEach { searchBooksById.removeValue(forKey: $0) }
        }

        // Clear old controllers and models (weak references auto-cleanup deallocated controllers)
        // Remove nil weak references
        pdfControllerById = pdfControllerById.filter { $0.value.viewController != nil }
        epubControllerById = epubControllerById.filter { $0.value.viewController != nil }

        epubPublicationById.removeAll()
        audioModelById.removeAll()
        pdfContentById.removeAll()
        catalogFilterStatesByURL.removeAll()

        Log.info(#file, "🧹 NavigationCoordinator: Cleaned up cached items (weak controllers preserved if still alive)")
    }

    func resolveBook(for route: BookRoute) -> TPPBook? {
        bookById[route.id]
    }

    func storeSearchBooks(_ books: [TPPBook]) -> SearchRoute {
        let key = UUID()
        searchBooksById[key] = books
        return SearchRoute(id: key)
    }

    func resolveSearchBooks(for route: SearchRoute) -> [TPPBook] {
        searchBooksById[route.id] ?? []
    }

    // MARK: - Controllers
    func storePDFController(_ controller: UIViewController, forBookId id: String) {
        pdfControllerById[id] = WeakViewController(controller)
        scheduleCleanupIfNeeded()
    }

    func resolvePDFController(for route: BookRoute) -> UIViewController? {
        pdfControllerById[route.id]?.viewController
    }

    func storeEPUBController(_ controller: UIViewController, forBookId id: String) {
        epubControllerById[id] = WeakViewController(controller)
        scheduleCleanupIfNeeded()
    }

    func resolveEPUBController(for route: BookRoute) -> UIViewController? {
        epubControllerById[route.id]?.viewController
    }

    func storeEPUBPublication(_ publication: Publication, forBookId id: String, forSample: Bool) {
        epubPublicationById[id] = (publication, forSample)
        scheduleCleanupIfNeeded()
    }

    func resolveEPUBPublication(for route: BookRoute) -> (Publication, Bool)? {
        epubPublicationById[route.id]
    }

    // MARK: - EPUB Sample Modal Presentation

    func presentEPUBSample(_ publication: Publication, forBookId id: String) {
        Log.debug(#file, "📕 Presenting EPUB sample as fullScreenCover for book: \(id)")
        presentedEPUBSample = EPUBPresentationData(bookId: id, publication: publication)
    }

    func dismissEPUBSample() {
        Log.debug(#file, "📕 Dismissing EPUB sample fullScreenCover")
        presentedEPUBSample = nil
    }

    // MARK: - SwiftUI payloads
    func storeAudioModel(_ model: AudiobookPlaybackModel, forBookId id: String) {
        audioModelById[id] = model
        scheduleCleanupIfNeeded()
    }

    func resolveAudioModel(for route: BookRoute) -> AudiobookPlaybackModel? {
        audioModelById[route.id]
    }

    func removeAudioModel(forBookId id: String) {
        audioModelById.removeValue(forKey: id)
    }

    func storePDF(document: TPPPDFDocument, metadata: TPPPDFDocumentMetadata, forBookId id: String) {
        pdfContentById[id] = (document, metadata)
    }

    func resolvePDF(for route: BookRoute) -> (TPPPDFDocument, TPPPDFDocumentMetadata)? {
        pdfContentById[route.id]
    }

    /// What the `.pdf` route shows for a book.
    enum PDFRouteContent {
        /// LCP PDF still being decrypted to disk: show the loading view.
        case extracting(TPPBook)
        /// A PDFKit document is ready.
        case reader(TPPPDFDocument, TPPPDFDocumentMetadata)
        case empty
    }

    /// The pending extract wins over a stored document so a re-open of a book
    /// whose earlier document is still cached shows the loader, not stale pages.
    func pdfRouteContent(for route: BookRoute) -> PDFRouteContent {
        if isLCPPDFExtractPending(for: route), let book = resolveBook(for: route) {
            return .extracting(book)
        }
        if let (document, metadata) = resolvePDF(for: route) {
            return .reader(document, metadata)
        }
        return .empty
    }

    /// Marks an LCP PDF extract as in progress. The `.pdf` route shows the
    /// loading view until the extract completes or the open is torn down.
    func markLCPPDFExtractPending(forBookId id: String) {
        lcpPDFExtractPending.insert(id)
    }

    /// Marks the extract pending and pushes its `.pdf` route. `onBackOut` runs
    /// once if the route leaves the stack (back button, swipe-back, pop to
    /// root) while the extract is still pending. The loader-to-reader switch
    /// keeps the route on the stack, so it does not run `onBackOut`.
    func pushLCPPDFExtractRoute(forBookId id: String, onBackOut: @escaping () -> Void) {
        markLCPPDFExtractPending(forBookId: id)
        push(.pdf(BookRoute(id: id)))
        pendingLCPPDFRoutes[id] = (depth: path.count, onBackOut: onBackOut)
    }

    /// Runs the back-out for every pending LCP PDF route the path no longer
    /// reaches, and clears its pending flag.
    private func backOutLCPPDFRoutesNoLongerOnStack() {
        let departed = pendingLCPPDFRoutes.filter { $0.value.depth > path.count }
        for (id, route) in departed {
            pendingLCPPDFRoutes.removeValue(forKey: id)
            lcpPDFExtractPending.remove(id)
            route.onBackOut()
        }
    }

    /// Hands the extracted PDF to the route: stores the PDFKit document, then
    /// clears the pending flag, whose publish re-renders the route.
    func completeLCPPDFExtract(document: TPPPDFDocument, metadata: TPPPDFDocumentMetadata, forBookId id: String) {
        storePDF(document: document, metadata: metadata, forBookId: id)
        clearLCPPDFExtractPending(forBookId: id)
    }

    /// Clears the pending flag without a document, for failed or abandoned
    /// opens. The route then shows nothing rather than the loading view.
    func clearLCPPDFExtractPending(forBookId id: String) {
        lcpPDFExtractPending.remove(id)
        pendingLCPPDFRoutes.removeValue(forKey: id)
    }

    /// `true` from the push of an LCP PDF route until its extract completes,
    /// the open is torn down, or the route leaves the stack.
    func isLCPPDFExtractPending(for route: BookRoute) -> Bool {
        lcpPDFExtractPending.contains(route.id)
    }

    // MARK: - Catalog Filter State Management

    func storeCatalogFilterState(_ state: CatalogLaneFilterState, for url: URL) {
        let key = makeURLKey(url)
        catalogFilterStatesByURL[key] = state
    }

    func resolveCatalogFilterState(for url: URL) -> CatalogLaneFilterState? {
        let key = makeURLKey(url)
        return catalogFilterStatesByURL[key]
    }

    func clearCatalogFilterState(for url: URL) {
        let key = makeURLKey(url)
        catalogFilterStatesByURL.removeValue(forKey: key)
    }

    func clearAllCatalogFilterStates() {
        catalogFilterStatesByURL.removeAll()
    }

    private func makeURLKey(_ url: URL) -> String {
        return "\(url.path)?\(url.query ?? "")"
    }
}

// MARK: - Catalog Filter State

struct CatalogLaneFilterState {
    let appliedSelections: Set<String>
    let facetGroups: [CatalogFilterGroup]
}
