import SwiftUI
import UIKit

/// High-level app routes for SwiftUI NavigationStack.
/// Extend incrementally as new flows migrate to SwiftUI.
enum AppRoute: Hashable {
  case bookDetail(BookRoute)
  case catalogLaneMore(title: String, url: URL)
  case search(SearchRoute)
  case pdf(BookRoute)
  case audio(BookRoute)
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
final class NavigationCoordinator: ObservableObject {
  @Published var path = NavigationPath()

  /// Transient payload storage keyed by stable identifiers.
  /// This lets us resolve non-hashable models like Objective-C `TPPBook` at destination time.
  private var bookById: [String: TPPBook] = [:]
  private var searchBooksById: [UUID: [TPPBook]] = [:]
  private var pdfControllerById: [String: UIViewController] = [:]
  private var audioControllerById: [String: UIViewController] = [:]

  // MARK: - Public API

  func push(_ route: AppRoute) {
    path.append(route)
  }

  func pop() {
    guard !path.isEmpty else { return }
    path.removeLast()
  }

  func popToRoot() {
    path.removeLast(path.count)
  }

  func store(book: TPPBook) {
    bookById[book.identifier] = book
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
}


