import SwiftUI
import UIKit
import PalaceAudiobookToolkit

/// High-level app routes for SwiftUI NavigationStack.
/// Extend incrementally as new flows migrate to SwiftUI.
enum AppRoute: Hashable {
  case bookDetail(BookRoute)
  case catalogLaneMore(title: String, url: URL)
  case search(SearchRoute)
  case pdf(BookRoute)
  case audio(BookRoute)
  case epub(BookRoute)
}

/// Lightweight, hashable identifier for a book navigation route.
/// Holds only stable identity for navigation path hashing.
struct BookRoute: Hashable {
  let id: String
}

struct SearchRoute: Hashable {
  let id: UUID
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
  @Published var path = NavigationPath()

  /// Transient payload storage keyed by stable identifiers.
  /// This lets us resolve non-hashable models like Objective-C `TPPBook` at destination time.
  private var bookById: [String: TPPBook] = [:]
  private var searchBooksById: [UUID: [TPPBook]] = [:]
  
  /// Weak references to prevent retain cycles
  private var pdfControllerById: [String: WeakViewController] = [:]
  private var epubControllerById: [String: WeakViewController] = [:]
  
  private var audioModelById: [String: AudiobookPlaybackModel] = [:]
  private var pdfContentById: [String: (TPPPDFDocument, TPPPDFDocumentMetadata)] = [:]
  private var catalogFilterStatesByURL: [String: CatalogLaneFilterState] = [:]
  
  private let maxStoredItems = 100
  private var cleanupTask: Task<Void, Never>?

  // MARK: - Public API

  func push(_ route: AppRoute) {
    withAnimation(.easeInOut) {
      path.append(route)
    }
  }

  func pop() {
    guard !path.isEmpty else { return }
    withAnimation(.easeInOut) {
      path.removeLast()
    }
  }

  func popToRoot() {
    guard !path.isEmpty else { return }
    withAnimation(.easeInOut) {
      path.removeLast(path.count)
    }
  }

  func store(book: TPPBook) {
    bookById[book.identifier] = book
    scheduleCleanupIfNeeded()
  }
  
  private func scheduleCleanupIfNeeded() {
    let totalItems = bookById.count + searchBooksById.count + pdfControllerById.count + 
                    epubControllerById.count + audioModelById.count + 
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


