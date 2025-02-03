import Combine
import SwiftUI

protocol BookDetailViewDelegate: AnyObject {
  func didSelectCancelDownloadFailed(for detailView: TPPBookDetailView)
  func didSelectCancelDownloading(for detailView: TPPBookDetailView)
  func didSelectCloseButton(for detailView: TPPBookDetailView)
  func didSelectMoreBooks(for lane: TPPCatalogLane)
  func didSelectReportProblem(for book: TPPBook, sender: Any)
  func didSelectViewIssues(for book: TPPBook, sender: Any)
}

@objcMembers class BookDetailViewModel: NSObject, ObservableObject {
  @Published var book: TPPBook
  @Published var state: TPPBookState
  @Published var bookmarks: [TPPReadiumBookmark] = []
  @Published var coverImage: UIImage = UIImage()
  @Published var backgroundColor: Color = .gray
  @Published var renderedSummary: NSAttributedString?
  @Published var buttonState: BookButtonState = .unsupported

  private var cancellables = Set<AnyCancellable>()
  private let registry: TPPBookRegistryProvider


  @objc init(book: TPPBook) {
    self.book = book
    self.registry = TPPBookRegistry.shared
    self.state = registry.state(for: book.identifier)

    super.init()
    bindRegistry()
    loadCoverImage(book: book)
    determineButtonState()
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

  private func determineButtonState() {
    switch state {
    case .unregistered:
      buttonState = .canBorrow
    case .downloadNeeded:
      buttonState = .downloadNeeded
    case .downloading:
      buttonState = .downloadInProgress
    case .downloadSuccessful:
      buttonState = .downloadSuccessful
    case .holding:
      buttonState = .holding
    case .downloadFailed:
      buttonState = .downloadFailed
    case .used:
      buttonState = .used
    default:
      buttonState = .unsupported
    }
  }

  func handleAction(for buttonType: BookButtonType) {
    switch buttonType {
    case .get:
      registry.setState(.downloadNeeded, for: book.identifier)
    case .reserve:
      registry.setState(.holding, for: book.identifier)
    case .remove, .return:
      registry.setState(.unregistered, for: book.identifier)
    case .download:
      registry.setState(.downloading, for: book.identifier)
    case .read, .listen:
      openBook()
    case .cancel:
      registry.setState(.unregistered, for: book.identifier)
    case .retry:
      registry.setState(.downloading, for: book.identifier)
    case .sample, .audiobookSample:
      playSample()
    }
  }

  private func updateCoverImage(_ uiImage: UIImage?) {
    guard let uiImage = uiImage else { return }
    DispatchQueue.main.async {
      self.coverImage = uiImage
      self.backgroundColor = Color(uiImage.mainColor() ?? .gray)
    }
  }

  private func openBook() {
    // Logic to open the book
  }

  private func playSample() {
    // Logic to play sample
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


//extension BookDetailViewModel: TPPBookDownloadCancellationDelegate {
//  func didCloseDetailView() {
//    <#code#>
//  }
//  
//  func didSelectCancel(forBookDetailDownloadingView view: TPPBookButtonsView?) {
//    <#code#>
//  }
//  
//  func didSelectCancel(forBookDetailDownloadFailedView failedView: TPPBookButtonsView?) {
//    <#code#>
//  }
//}
//
//extension BookDetailViewModel: BookDetailViewDelegate {
//  func didSelectCancelDownloadFailed(for detailView: TPPBookDetailView) {
//    <#code#>
//  }
//
//  func didSelectCancelDownloading(for detailView: TPPBookDetailView) {
//    <#code#>
//  }
//
//  func didSelectCloseButton(for detailView: TPPBookDetailView) {
//    <#code#>
//  }
//
//  func didSelectMoreBooks(for lane: TPPCatalogLane) {
//    <#code#>
//  }
//
//  func didSelectReportProblem(for book: TPPBook, sender: Any) {
//    <#code#>
//  }
//
//  func didSelectViewIssues(for book: TPPBook, sender: Any) {
//    <#code#>
//  }
//}
