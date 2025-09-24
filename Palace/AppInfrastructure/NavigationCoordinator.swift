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

/// Centralized coordinator for NavigationStack-based routing.
/// Owns a NavigationPath and transient payload storage to resolve non-hashable models.
@MainActor
final class NavigationCoordinator: ObservableObject {
  @Published var path = NavigationPath()

  /// Transient payload storage keyed by stable identifiers.
  /// This lets us resolve non-hashable models like Objective-C `TPPBook` at destination time.
  private var bookById: [String: TPPBook] = [:]
  private var searchBooksById: [UUID: [TPPBook]] = [:]
  private var pdfControllerById: [String: UIViewController] = [:]
  private var audioControllerById: [String: UIViewController] = [:]
  private var epubControllerById: [String: UIViewController] = [:]
  private var audioModelById: [String: AudiobookPlaybackModel] = [:]
  private var pdfContentById: [String: (TPPPDFDocument, TPPPDFDocumentMetadata)] = [:]
  
  private let maxStoredItems = 100
  private var cleanupTimer: Timer?

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
                    audioControllerById.count + epubControllerById.count + audioModelById.count + 
                    pdfContentById.count
    
    if totalItems > maxStoredItems {
      cleanupTimer?.invalidate()
      cleanupTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
        self?.performCleanup()
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
    
    // Clear old controllers and models
    pdfControllerById.removeAll()
    audioControllerById.removeAll() 
    epubControllerById.removeAll()
    audioModelById.removeAll()
    pdfContentById.removeAll()
    
    
    Log.info(#file, "🧹 NavigationCoordinator: Cleaned up cached items")
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
    pdfControllerById[id] = controller
  }

  func resolvePDFController(for route: BookRoute) -> UIViewController? {
    pdfControllerById[route.id]
  }

  func storeAudioController(_ controller: UIViewController, forBookId id: String) {
    audioControllerById[id] = controller
  }

  func resolveAudioController(for route: BookRoute) -> UIViewController? {
    audioControllerById[route.id]
  }

  func storeEPUBController(_ controller: UIViewController, forBookId id: String) {
    epubControllerById[id] = controller
  }

  func resolveEPUBController(for route: BookRoute) -> UIViewController? {
    epubControllerById[route.id]
  }

  // MARK: - SwiftUI payloads
  func storeAudioModel(_ model: AudiobookPlaybackModel, forBookId id: String) {
    // Replace any existing model (allows reopening the same book)
    audioModelById[id] = model
    scheduleCleanupIfNeeded()
  }

  func resolveAudioModel(for route: BookRoute) -> AudiobookPlaybackModel? {
    audioModelById[route.id]
  }

  func storePDF(document: TPPPDFDocument, metadata: TPPPDFDocumentMetadata, forBookId id: String) {
    pdfContentById[id] = (document, metadata)
  }

  func resolvePDF(for route: BookRoute) -> (TPPPDFDocument, TPPPDFDocumentMetadata)? {
    pdfContentById[route.id]
  }
}


