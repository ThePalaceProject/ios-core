import SwiftUI
import Combine

@objcMembers class BookDetailViewModel: NSObject, ObservableObject {
  @Published var book: TPPBook
  @Published var state: TPPBookState
  @Published var bookmarks: [TPPReadiumBookmark] = []
  @Published var coverImage: Image = Image(systemName: "book")

  private var cancellables = Set<AnyCancellable>()
  private let registry: TPPBookRegistryProvider


  @objc init(book: TPPBook) {
    self.book = book
    self.registry = TPPBookRegistry.shared
    self.state = registry.state(for: book.identifier)

    super.init()
    bindRegistry()
    loadCoverImage(book: book)
  }

  // MARK: - Registry Binding
  private func bindRegistry() {
    // Subscribe to state updates for the current book
    registry.bookStatePublisher
      .filter { $0.0 == self.book.identifier }
      .map { $0.1 }
      .receive(on: DispatchQueue.main)
      .assign(to: &$state)

    // Subscribe to bookmark updates (if needed)
    //      registry.bookmarksPublisher
    //        .filter { $0.0 == self.book.identifier }
    //        .map { $0.1 }
    //        .receive(on: DispatchQueue.main)
    //        .assign(to: &$bookmarks)
  }

  // MARK: - Load Cover Image
  private func loadCoverImage(book: TPPBook) {
    registry.coverImage(for: book) { [weak self] uiImage in
      guard let self else { return }
      if let uiImage {
        DispatchQueue.main.async {
          self.coverImage = Image(uiImage: uiImage)
        }
      }
    }
    //      registry.coverImage(for: book) { [weak self] uiImage in
    //        guard let self else { return }
    //        if let uiImage {
    //          DispatchQueue.main.async {
    //            self.coverImage = Image(uiImage: uiImage)
    //          }
    //        }
    //      }
  }

  // MARK: - Bookmark Management
  func addBookmark(_ bookmark: TPPReadiumBookmark) {
    registry.add(bookmark, forIdentifier: book.identifier)
  }

  func deleteBookmark(_ bookmark: TPPReadiumBookmark) {
    registry.delete(bookmark, forIdentifier: book.identifier)
  }

  // MARK: - State Management
  func updateState(to newState: TPPBookState) {
    registry.setState(newState, for: book.identifier)
  }
}
