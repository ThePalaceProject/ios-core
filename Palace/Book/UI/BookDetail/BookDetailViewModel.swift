
import Combine
import SwiftUI

class BookDetailViewModel: ObservableObject {
  // MARK: - Published State

  /// The book model.
  @Published var book: TPPBook

  /// The registry state, e.g. `unregistered`, `downloading`, `downloadSuccessful` etc.
  @Published var state: TPPBookState

  /// Misc published fields for UI updates.
  @Published var bookmarks: [TPPReadiumBookmark] = []
  @Published var showSampleToolbar = false
  @Published var downloadProgress: Double = 0.0
  @Published var isPresentingHalfSheet = false

  @Published var buttonState: BookButtonState = .unsupported
  @Published var relatedBooks: [TPPBook] = []
  @Published var isLoadingRelatedBooks = false
  @Published var isLoadingDescription = false

  @Published private var processingButtons: Set<BookButtonType> = []

  var isShowingSample = false
  var isProcessingSample = false

  // MARK: - Dependencies
  let registry: TPPBookRegistryProvider
  let downloadCenter = MyBooksDownloadCenter.shared
  private var cancellables = Set<AnyCancellable>()

  // MARK: - Initializer
  @objc init(book: TPPBook) {
    self.book = book
    self.registry = TPPBookRegistry.shared
    self.state = registry.state(for: book.identifier)

    bindRegistryState()
    determineButtonState()
    setupObservers()
    self.downloadProgress = downloadCenter.downloadProgress(for: book.identifier)
  }

  // MARK: - Book State Binding

  /// Automatically updates `state` whenever `registry.bookStatePublisher` changes for this book.
  private func bindRegistryState() {
    registry.bookStatePublisher
      .filter { $0.0 == self.book.identifier }
      .map { $0.1 }
      .receive(on: DispatchQueue.main)
      .assign(to: &$state)
  }

  /// Listen for notifications (like the old TPPBookDetailViewController).
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
  }

  func selectRelatedBook(_ newBook: TPPBook) {
    guard newBook.identifier != book.identifier else { return }
    book = newBook
//    loadCoverImage(book: book)
    determineButtonState()
    fetchRelatedBooks()
  }

  // MARK: - Notifications

  @objc func handleBookRegistryChange(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let newBook = registry.book(forIdentifier: book.identifier) ?? book
      self.book = newBook
      self.state = registry.state(for: book.identifier)
      determineButtonState()
    }
  }

  @objc func handleMyBooksDidChange(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // Update progress from MyBooksDownloadCenter
      self.downloadProgress = downloadCenter.downloadProgress(for: book.identifier)
      let info = downloadCenter.downloadInfo(forBookIdentifier: book.identifier)
      if let rights = info?.rightsManagement, rights != .unknown {
        // If user started a download or it's in progress
        if state != .downloading {
          state = .downloading
        }
      }
    }
  }

  func fetchRelatedBooks() {
    guard let url = book.relatedWorksURL else { return }

    isLoadingRelatedBooks = true // Start loading
    TPPOPDSFeed.withURL(url, shouldResetCache: false, useTokenIfAvailable: TPPUserAccount.sharedAccount().hasAdobeToken()) { [weak self] feed, _ in
      guard let self = self, feed?.type == .acquisitionGrouped, let groupedFeed = TPPCatalogGroupedFeed(opdsFeed: feed) else {
        self?.isLoadingRelatedBooks = false
        return
      }

      let books: [TPPBook] = groupedFeed.lanes.compactMap { lane in
        if let catalogLane = lane as? TPPCatalogLane {
          return catalogLane.books as? [TPPBook]
        } else {
          return nil
        }
      }.flatMap { $0 }

      DispatchQueue.main.async {
        self.relatedBooks = books.filter { $0.identifier != self.book.identifier }
        self.isLoadingRelatedBooks = false
      }
    }
  }
  
  // MARK: - Button State Mapping

  /// Maps registry `state` to `buttonState` for simpler SwiftUI usage.
  private func determineButtonState() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }

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
  }

  // MARK: - Actions: Unified Handle

  /// Central entry point for handling button taps (download, read, cancel, return, etc.).
  func handleAction(for button: BookButtonType) {
    guard !isProcessing(for: button) else { return }
    processingButtons.insert(button)

    switch button {
    case .reserve:
      registry.setState(.holding, for: book.identifier)
      self.processingButtons.remove(button)

    case .remove:
      registry.setState(.unregistered, for: book.identifier)
      self.processingButtons.remove(button)

    case .return:
      didSelectReturn(for: book) {
        self.processingButtons.remove(button)
      }

    case .download, .get, .retry:
      if isPresentingHalfSheet {
        if buttonState == .canHold {
          TPPUserNotifications.requestAuthorization()
        }
        didSelectDownload(for: book)
      } else {
        self.processingButtons.remove(button)
        isPresentingHalfSheet = true
      }

    case .read, .listen:
      didSelectRead(for: book) {
        self.processingButtons.remove(button)
      }

    case .cancel:
      didSelectCancel()
      self.processingButtons.remove(button)

    case .sample, .audiobookSample:
      didSelectPlaySample(for: book) {
        self.processingButtons.remove(button)
      }
    }
  }

  // Helper
  func isProcessing(for button: BookButtonType) -> Bool {
    processingButtons.contains(button)
  }

  // MARK: - Download/Return/Cancel

  /// Start or retry download
  func didSelectDownload(for book: TPPBook) {
    downloadCenter.startDownload(for: book)
    // We'll rely on .downloading state from MyBooksDownloadCenter to update progress
  }

  /// Cancel any current download
  func didSelectCancel() {
    downloadCenter.cancelDownload(for: book.identifier)
    self.downloadProgress = 0
  }

  /// Return the book
  func didSelectReturn(for book: TPPBook, completion: (() -> Void)?) {
    downloadCenter.returnBook(withIdentifier: book.identifier, completion: completion)
  }

  // MARK: - Reading

  /// "Read" or "Listen" action
  func didSelectRead(for book: TPPBook, completion: (() -> Void)?) {
#if FEATURE_DRM_CONNECTOR
    // Insert any authentication logic here if needed
#endif
    openBook(book, completion: completion)
  }

  /// Opens the given book in the correct reader (EPUB, PDF, or Audiobook).
  func openBook(_ book: TPPBook, completion: (() -> Void)?) {
    TPPCirculationAnalytics.postEvent("open_book", withBook: book)

    switch book.defaultBookContentType {
    case .epub:
      presentEPUB(book)
    case .pdf:
      presentPDF(book)
    case .audiobook:
      openAudiobook(book, completion: completion)
    default:
      presentUnsupportedItemError()
    }
  }

  private func presentEPUB(_ book: TPPBook) {
    TPPRootTabBarController.shared().presentBook(book)
  }

  private func presentPDF(_ book: TPPBook) {
    guard let bookUrl = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier) else { return }
    let data = try? Data(contentsOf: bookUrl)
    let metadata = TPPPDFDocumentMetadata(with: book)
    let document = TPPPDFDocument(data: data ?? Data())
    let pdfViewController = TPPPDFViewController.create(document: document, metadata: metadata)
    TPPRootTabBarController.shared().pushViewController(pdfViewController, animated: true)
  }

  // MARK: - Audiobook Opening

  func openAudiobook(_ book: TPPBook, completion: (() -> Void)?) {
    guard let url = downloadCenter.fileUrl(for: book.identifier) else {
      presentCorruptedItemError(for: book)
      completion?()
      return
    }

    do {
      let data = try Data(contentsOf: url)
      guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        presentUnsupportedItemError()
        completion?()
        return
      }

      // Overdrive? Possibly set `json["id"] = book.identifier`
      openAudiobook(with: book, json: json, drmDecryptor: nil, completion: completion)
    } catch {
      presentCorruptedItemError(for: book)
      completion?()
    }
  }

  func openAudiobook(with book: TPPBook, json: [String: Any], drmDecryptor: DRMDecryptor?, completion: (() -> Void)?) {
    AudioBookVendorsHelper.updateVendorKey(book: json) { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if let error {
          self.presentDRMKeyError(error)
          completion?()
          return
        }

        // Decode the manifest, open the audiobook
        let manifestDecoder = Manifest.customDecoder()
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []),
              let manifest = try? manifestDecoder.decode(Manifest.self, from: jsonData),
              let audiobook = AudiobookFactory.audiobook(
                for: manifest,
                bookIdentifier: book.identifier,
                decryptor: drmDecryptor,
                token: book.bearerToken
              ) else {
          self.presentUnsupportedItemError()
          completion?()
          return
        }

        let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""])
        let audiobookManager = DefaultAudiobookManager(
          metadata: metadata,
          audiobook: audiobook,
          networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
        )

        let audiobookPlayer = AudiobookPlayer(audiobookManager: audiobookManager)
        TPPRootTabBarController.shared().pushViewController(audiobookPlayer, animated: true)

        // etc. (restore location, scheduling timers, etc.)

        completion?()
      }
    }
  }

  // MARK: - Samples

  func didSelectPlaySample(for book: TPPBook, completion: (() -> Void)?) {
    guard !isProcessingSample else { return }
    isProcessingSample = true

    if book.defaultBookContentType == .audiobook {
      // Audiobook Sample
      if book.sampleAcquisition?.type == "text/html" {
        presentWebView(book.sampleAcquisition?.hrefURL)
      } else if !isShowingSample {
        isShowingSample = true
        showSampleToolbar = true
        isProcessingSample = false
      }
      NotificationCenter.default.post(name: Notification.Name("ToggleSampleNotification"), object: self)
    } else {
      // EPUB Sample
      EpubSampleFactory.createSample(book: book) { sampleURL, error in
        DispatchQueue.main.async {
          if let error = error {
            Log.debug("Sample generation error for \(book.title): \(error.localizedDescription)", "")
          } else if let sampleWebURL = sampleURL as? EpubSampleWebURL {
            self.presentWebView(sampleWebURL.url)
          } else if let sampleURL = sampleURL?.url {
            TPPRootTabBarController.shared().presentSample(book, url: sampleURL)
          }
          self.isProcessingSample = false
        }
      }
    }

    completion?()
  }

  private func presentWebView(_ url: URL?) {
    guard let url = url else { return }
    let webController = BundledHTMLViewController(fileURL: url, title: AccountsManager.shared.currentAccount?.name ?? "")
    TPPRootTabBarController.shared().pushViewController(webController, animated: true)
  }

  // MARK: - Error Alerts

  private func presentCorruptedItemError(for book: TPPBook) {
    let alert = UIAlertController(
      title: NSLocalizedString("Corrupted Audiobook", comment: ""),
      message: NSLocalizedString("The audiobook you are trying to open appears to be corrupted. Try downloading it again.", comment: ""),
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }

  private func presentUnsupportedItemError() {
    let alert = UIAlertController(
      title: NSLocalizedString("Unsupported Item", comment: ""),
      message: NSLocalizedString("This item format is not supported.", comment: ""),
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }

  private func presentDRMKeyError(_ error: Error) {
    let alert = UIAlertController(title: "DRM Error", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
}
