import Combine
import SwiftUI

@objcMembers class BookDetailViewModel: NSObject, ObservableObject {
  @Published var book: TPPBook
  @Published var state: TPPBookState
  @Published var bookmarks: [TPPReadiumBookmark] = []
  @Published var coverImage: UIImage = UIImage()
  @Published var backgroundColor: Color = .gray
  @Published var renderedSummary: NSAttributedString?

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
      guard let self = self else { return }
      self.updateCoverImage(uiImage)
    }
  }

  private func updateCoverImage(_ uiImage: UIImage?) {
    guard let uiImage = uiImage else { return }
    DispatchQueue.main.async {
      self.coverImage = uiImage
      self.backgroundColor = Color(uiImage.mainColor() ?? .gray)
    }
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
