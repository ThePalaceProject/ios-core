import Combine
import SwiftUI
import PalaceAudiobookToolkit

struct BookLane {
  let title: String
  let books: [TPPBook]
  let subsectionURL: URL?
}

final class BookDetailViewModel: ObservableObject {
  @Published var book: TPPBook

  /// The registry state, e.g. `unregistered`, `downloading`, `downloadSuccessful`, etc.
  @Published var bookState: TPPBookState

  @Published var bookmarks: [TPPReadiumBookmark] = []
  @Published var showSampleToolbar = false
  @Published var downloadProgress: Double = 0.0

  @Published var relatedBooksByLane: [String: BookLane] = [:]
  @Published var isLoadingRelatedBooks = false
  @Published var isLoadingDescription = false
  @Published var selectedBookURL: URL? = nil

  var isFullSize: Bool { UIDevice.current.isIpad }

  @Published private var processingButtons: Set<BookButtonType> = [] {
    didSet {
      isProcessing = processingButtons.count > 0
    }
  }
  @Published var isProcessing: Bool = false

  var isShowingSample = false
  var isProcessingSample = false

  // MARK: - Dependencies

  let registry: TPPBookRegistry
  let downloadCenter = MyBooksDownloadCenter.shared
  private var cancellables = Set<AnyCancellable>()

  private var audiobookViewController: UIViewController?
  private var audiobookManager: DefaultAudiobookManager?
  private var audiobookPlayer: AudiobookPlayer?
  private var audiobookBookmarkBusinessLogic: AudiobookBookmarkBusinessLogic?
  private var timer: DispatchSourceTimer?
  private var previousPlayheadOffset: TimeInterval = 0

  // MARK: – Computed Button State

  /// Combines registry state + OPDS availability + download progress into one state.
  var buttonState: BookButtonState {
    let isDownloading = (bookState == .downloading) || (downloadProgress > 0 && downloadProgress < 1.0)
    let avail = book.defaultAcquisition?.availability
    return BookButtonMapper.map(
      registryState: bookState,
      availability: avail,
      isProcessingDownload: isDownloading
    )
  }

  // MARK: - Initializer

  @objc init(book: TPPBook) {
    self.book = book
    self.registry = TPPBookRegistry.shared
    self.bookState = registry.state(for: book.identifier)

    bindRegistryState()
    setupObservers()
    self.downloadProgress = downloadCenter.downloadProgress(for: book.identifier)
  }

  deinit {
    timer?.cancel()
    timer = nil
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Book State Binding

  /// Subscribe to the registry's publisher and update `bookState`.
  private func bindRegistryState() {
    (registry as? TPPBookRegistry)?
      .bookStatePublisher
      .filter { $0.0 == self.book.identifier }
      .map { $0.1 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] newState in
        guard let self = self else { return }
        self.bookState = newState
        // No need to call a separate `determineButtonState()`—the computed
        // `buttonState` will automatically reflect `bookState`.
      }
      .store(in: &cancellables)
  }

  private func setupObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleBookRegistryChange(_:)),
      name: .TPPBookRegistryDidChange,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMyBooksDidChange(_:)),
      name: .TPPMyBooksDownloadCenterDidChange,
      object: nil
    )

    downloadCenter.downloadProgressPublisher
      .filter { $0.0 == self.book.identifier }
      .map { $0.1 }
      .receive(on: DispatchQueue.main)
      .assign(to: &$downloadProgress)
  }

  /// Swap in a new book when user taps a related book
  func selectRelatedBook(_ newBook: TPPBook) {
    guard newBook.identifier != book.identifier else { return }
    book = newBook
    bookState = registry.state(for: newBook.identifier)
    fetchRelatedBooks()
    // computed `buttonState` will update automatically
  }

  // MARK: - Notifications

  @objc func handleBookRegistryChange(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let updatedBook = registry.book(forIdentifier: book.identifier) ?? book
      self.book = updatedBook
      self.bookState = registry.state(for: book.identifier)
      // computed `buttonState` auto‐updates
    }
  }

  @objc func handleMyBooksDidChange(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.downloadProgress = downloadCenter.downloadProgress(for: book.identifier)
      let info = downloadCenter.downloadInfo(forBookIdentifier: book.identifier)
      if let rights = info?.rightsManagement, rights != .unknown {
        if bookState != .downloading && bookState != .downloadSuccessful {
          self.bookState = .downloading
        }
      }
      // computed `buttonState` auto‐updates
    }
  }

  // MARK: - Related Books

  func fetchRelatedBooks() {
    guard let url = book.relatedWorksURL else { return }

    isLoadingRelatedBooks = true
    relatedBooksByLane = [:]

    TPPOPDSFeed.withURL(url, shouldResetCache: false, useTokenIfAvailable: TPPUserAccount.sharedAccount().hasAdobeToken()) { [weak self] feed, _ in
      guard let self = self else { return }

      DispatchQueue.main.async {
        if feed?.type == .acquisitionGrouped {
          let groupedFeed = TPPCatalogGroupedFeed(opdsFeed: feed)
          self.createRelatedBooksCells(groupedFeed)
        } else {
          self.isLoadingRelatedBooks = false
        }
      }
    }
  }

  private func createRelatedBooksCells(_ groupedFeed: TPPCatalogGroupedFeed?) {
    guard let feed = groupedFeed else {
      self.isLoadingRelatedBooks = false
      return
    }

    var groupedBooks = [String: BookLane]()

    for lane in feed.lanes as! [TPPCatalogLane] {
      if let books = lane.books as? [TPPBook] {
        let laneTitle = lane.title ?? "Unknown Lane"
        let subsectionURL = lane.subsectionURL
        let bookLane = BookLane(title: laneTitle, books: books, subsectionURL: subsectionURL)
        groupedBooks[laneTitle] = bookLane
      }
    }

    // If the current book's author appears in one lane, move that lane to front
    if let author = book.authors, !author.isEmpty {
      if let authorLane = groupedBooks.first(where: { $0.value.books.contains(where: { $0.authors?.contains(author) ?? false }) }) {
        groupedBooks.removeValue(forKey: authorLane.key)
        var reorderedBooks = [String: BookLane]()
        reorderedBooks[authorLane.key] = authorLane.value
        reorderedBooks.merge(groupedBooks) { _, new in new }
        groupedBooks = reorderedBooks
      }
    }

    DispatchQueue.main.async {
      self.relatedBooksByLane = groupedBooks
      self.isLoadingRelatedBooks = false
    }
  }

  func showMoreBooksForLane(laneTitle: String) {
    guard let lane = relatedBooksByLane[laneTitle] else { return }
    if let subsectionURL = lane.subsectionURL {
      self.selectedBookURL = subsectionURL
    }
  }

  // MARK: - Button Actions

  func handleAction(for button: BookButtonType) {
    guard !isProcessing(for: button) else { return }
    processingButtons.insert(button)

    switch button {
    case .reserve:
      // "Reserve" means request a hold and immediately flip registry → .holding
      downloadCenter.startDownload(for: book)    // if you want to fetch a hold‐receipt, otherwise skip
      registry.setState(.holding, for: book.identifier)
      removeProcessingButton(button)

    case .return, .remove, .cancelHold:
      bookState = .returning
      removeProcessingButton(button)

    case .returning:
      didSelectReturn(for: book) {
        self.removeProcessingButton(button)
      }

    case .download, .get, .retry:
      didSelectDownload(for: book)
      removeProcessingButton(button)

    case .read, .listen:
      didSelectRead(for: book) {
        self.removeProcessingButton(button)
      }

    case .cancel:
      didSelectCancel()
      removeProcessingButton(button)

    case .sample, .audiobookSample:
      didSelectPlaySample(for: book) {
        self.removeProcessingButton(button)
      }

    case .close, .manageHold:
      break
    }
  }

  private func removeProcessingButton(_ button: BookButtonType) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      self.processingButtons.remove(button)
    }
  }

  func isProcessing(for button: BookButtonType) -> Bool {
    processingButtons.contains(button)
  }

  // MARK: - Download/Return/Cancel

  func didSelectDownload(for book: TPPBook) {
    downloadCenter.startDownload(for: book)
  }

  func didSelectCancel() {
    downloadCenter.cancelDownload(for: book.identifier)
    self.downloadProgress = 0
  }

  func didSelectReturn(for book: TPPBook, completion: (() -> Void)?) {
    downloadCenter.returnBook(withIdentifier: book.identifier, completion: completion)
  }

  // MARK: - Reading

  func didSelectRead(for book: TPPBook, completion: (() -> Void)?) {
    // Implementation
  }

  func didSelectPlaySample(for book: TPPBook, completion: (() -> Void)?) {
    // Implementation
  }
}

// MARK: – Helper Extensions (unchanged)
extension BookDetailViewModel {
  public func scheduleTimer() {
    // …unchanged…
  }

  @objc public func pollAudiobookReadingLocation() {
    // …unchanged…
  }
}

extension BookDetailViewModel {
  func chooseLocalLocation(localPosition: TrackPosition?, remotePosition: TrackPosition?, serverUpdateDelay: TimeInterval, operation: @escaping (TrackPosition) -> Void) {
    // …unchanged…
  }

  func requestSyncWithCompletion(completion: @escaping (Bool) -> Void) {
    // …unchanged…
  }
}

// MARK: – BookButtonProvider
extension BookDetailViewModel: BookButtonProvider {
  var buttonTypes: [BookButtonType] {
    return buttonState.buttonTypes(book: book)
  }
}

extension BookDetailViewModel: HalfSheetProvider {}
