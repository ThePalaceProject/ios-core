import SwiftUI
import UIKit
import PalaceAudiobookToolkit
import ReadiumShared
import PalaceLogging

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
    /// `@Published` so SwiftUI views observing the coordinator
    /// re-render when the publication arrives. Pushed BEFORE the
    /// publication opens — the reader view shows a loading state until
    /// this dict gains an entry for the route's book id.
    @Published private var readiumPDFById: [String: (Publication, TPPPDFDocumentMetadata)] = [:]
    /// Pre-loaded TOC + page count for the Readium-backed PDF, so the
    /// side panels (TOC view, preview grid) can render synchronously
    /// even though Readium's `tableOfContents()` and `positions()` are
    /// async. Populated by `ReaderService.openPDF` after the publication
    /// opens; dropped by `removeReadiumPDF` and on cleanup.
    @Published private var readiumPDFTOCById: [String: (toc: [TPPPDFLocation], pageCount: Int)] = [:]
    /// Books whose LCP PDF open is in progress. Pushed when the user taps
    /// Read, cleared when the **navigator emits its first
    /// `locationDidChange`** — i.e. page 1 has actually rendered, not
    /// merely "the publication object exists". `libraryService.openBook`
    /// returns in ~100ms on a fast device but Readium then has to walk
    /// the PDF cross-ref table through the LCP content protection layer
    /// (the hundreds of `decrypt 2064 -> 2048` calls), which can take
    /// minutes on large Marketplace containers. Without this we'd hide
    /// the loading view at T2 and show a blank navigator for the rest of
    /// the open.
    @Published private var readiumPDFPending: Set<String> = []
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

    func popToRoot() {
        guard !path.isEmpty else { return }
        isTopRouteAudio = false
        // Respect reduce motion accessibility setting
        if UIAccessibility.isReduceMotionEnabled {
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
            pdfContentById.count + readiumPDFById.count + catalogFilterStatesByURL.count

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
        // LCP PDF publications hold LCP content-protection state, an
        // HTTP-server endpoint, and decrypted page caches. Dropping them
        // on cleanup is necessary to avoid unbounded memory growth from
        // back-to-back opens.
        readiumPDFById.removeAll()
        readiumPDFTOCById.removeAll()
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

    /// Stores a Readium `Publication` + its metadata for LCP-protected PDFs.
    /// The `.pdf` route resolver prefers the Readium path when a publication
    /// is present, falling back to the legacy PDFKit path otherwise.
    func storeReadiumPDF(publication: Publication, metadata: TPPPDFDocumentMetadata, forBookId id: String) {
        readiumPDFById[id] = (publication, metadata)
        scheduleCleanupIfNeeded()
    }

    func resolveReadiumPDF(for route: BookRoute) -> (Publication, TPPPDFDocumentMetadata)? {
        readiumPDFById[route.id]
    }

    /// Stores the pre-loaded TOC + page count for a Readium-backed PDF.
    /// Loaded asynchronously by `ReaderService.openPDF` before the route
    /// pushes so the side panels can stay synchronous.
    func storeReadiumPDFTableOfContents(_ toc: [TPPPDFLocation], pageCount: Int, forBookId id: String) {
        readiumPDFTOCById[id] = (toc: toc, pageCount: pageCount)
    }

    func resolveReadiumPDFTableOfContents(for route: BookRoute) -> (toc: [TPPPDFLocation], pageCount: Int)? {
        readiumPDFTOCById[route.id]
    }

    /// Drops the cached `Publication` + metadata for an LCP-protected PDF so
    /// the LCP content-protection state, HTTP-server endpoint, and decrypted
    /// page caches can be released. Call from the reader view's `.onDisappear`
    /// when the user backs out — without this, every open accumulates a new
    /// publication and the app eventually OOMs on a large LCP textbook.
    ///
    /// Intentionally does NOT drop `readiumPDFTOCById`: the TOC + page count
    /// are pure metadata (a few KB) and re-loading them via Readium 3's
    /// async `tableOfContents()` / `positions()` requires re-opening the
    /// publication, which is exactly what we just released. Keeping the
    /// snapshot keyed by book id lets a re-open populate side panels
    /// instantly before the publication finishes its second open.
    func removeReadiumPDF(forBookId id: String) {
        readiumPDFById.removeValue(forKey: id)
        readiumPDFPending.remove(id)
    }

    /// Marks an LCP PDF open as in progress. The reader view (pushed
    /// IMMEDIATELY by `ReaderService.openPDF`) shows a loading state for
    /// any pending book id whose first page hasn't rendered yet.
    func markReadiumPDFPending(forBookId id: String) {
        readiumPDFPending.insert(id)
    }

    /// Called by `ReadiumPDFViewController` when the PDFNavigator emits
    /// its first `locationDidChange` — i.e. page 1 has actually rendered.
    /// Removes the book from `readiumPDFPending` so the host view drops
    /// the loading overlay.
    func markReadiumPDFFirstPageRendered(forBookId id: String) {
        readiumPDFPending.remove(id)
    }

    /// `true` while the LCP open + first-page render is still in flight.
    /// The host view shows `ReadiumPDFLoadingView` while this returns
    /// true; once the navigator emits its first locationDidChange,
    /// `markReadiumPDFFirstPageRendered` flips it off.
    func isReadiumPDFPending(for route: BookRoute) -> Bool {
        readiumPDFPending.contains(route.id)
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
