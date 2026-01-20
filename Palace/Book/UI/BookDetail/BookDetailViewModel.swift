import Combine
import SwiftUI
import PalaceAudiobookToolkit

#if LCP
import ReadiumShared
import ReadiumStreamer
#endif

struct BookLane {
  let title: String
  let books: [TPPBook]
  let subsectionURL: URL?
}

@MainActor
final class BookDetailViewModel: ObservableObject {
  // MARK: - Constants
  private let kTimerInterval: TimeInterval = 3.0
  
  @Published var book: TPPBook
  
  /// The registry state, e.g. `unregistered`, `downloading`, `downloadSuccessful`, etc.
  @Published var bookState: TPPBookState {
    didSet {
      if bookState == .returning {
        localBookStateOverride = .returning
      } else if bookState == .unregistered {
        localBookStateOverride = nil
      }
    }
  }
  
  @Published var bookmarks: [TPPReadiumBookmark] = []
  @Published var showSampleToolbar = false
  @Published var downloadProgress: Double = 0.0
  
  @Published var relatedBooksByLane: [String: BookLane] = [:]
  @Published var isLoadingRelatedBooks = false
  @Published var isLoadingDescription = false
  @Published var selectedBookURL: URL? = nil
  @Published var isManagingHold: Bool = false
  @Published var showHalfSheet = false
  @Published private(set) var stableButtonState: BookButtonState = .unsupported
  @Published var orientationChanged: Bool = false
  
  var isFullSize: Bool {
    guard UIDevice.current.isIpad else { return false }
    let screenWidth = UIScreen.main.bounds.width
    let screenHeight = UIScreen.main.bounds.height
    _ = orientationChanged
    return screenHeight > screenWidth
  }
  
  @Published var processingButtons: Set<BookButtonType> = [] {
    didSet {
      isProcessing = processingButtons.count > 0
    }
  }
  @Published var isProcessing: Bool = false
  
  var isShowingSample = false
  var isProcessingSample = false
  
  // MARK: - Dependencies
  
  let registry: TPPBookRegistryProvider
  let downloadCenter = MyBooksDownloadCenter.shared
  private var cancellables = Set<AnyCancellable>()
  
  // Note: audiobook management moved to BookService
  // private var audiobookViewController: UIViewController? // No longer used
  // private var audiobookManager: DefaultAudiobookManager? // No longer used
  private var audiobookPlayer: AudiobookPlayer?
  private var audiobookBookmarkBusinessLogic: AudiobookBookmarkBusinessLogic?
  private var timer: DispatchSourceTimer?
  private var previousPlayheadOffset: TimeInterval = 0
  private var didPrefetchLCPStreaming = false
  private var isReconcilingLocation: Bool = false
  private var recentMoveAt: Date? = nil
  private var isSyncingLocation: Bool = false
  private let bookIdentifier: String
  private var localBookStateOverride: TPPBookState? = nil
  
  // MARK: – Computed Button State
  
  var buttonState: BookButtonState { stableButtonState }
  
  // MARK: - Initializer
  
  @objc convenience init(book: TPPBook) {
    self.init(book: book, registry: TPPBookRegistry.shared)
  }
  
  /// Initializer with dependency injection for testing
  init(book: TPPBook, registry: TPPBookRegistryProvider) {
    self.book = book
    self.registry = registry
    self.bookState = registry.state(for: book.identifier)
    self.bookIdentifier = book.identifier
    self.stableButtonState = self.computeButtonState(book: book, state: self.bookState, isManagingHold: self.isManagingHold)
    
    bindRegistryState()
    setupStableButtonState()
    setupObservers()
    
    // Defer download progress check to avoid triggering cover fetch during init
    Task { @MainActor in
      self.downloadProgress = downloadCenter.downloadProgress(for: book.identifier)
    }
    
#if LCP
    self.prefetchLCPStreamingIfPossible()
#endif
  }
  
  deinit {
    timer?.cancel()
    timer = nil
    NotificationCenter.default.removeObserver(self)
#if LCP
    if let licenseUrl = Self.lcpLicenseURL(forBookIdentifier: bookIdentifier) {
      var lcpAudiobooks: LCPAudiobooks?
      if let localURL = MyBooksDownloadCenter.shared.fileUrl(for: bookIdentifier),
         FileManager.default.fileExists(atPath: localURL.path) {
        lcpAudiobooks = LCPAudiobooks(for: localURL)
      } else {
        lcpAudiobooks = LCPAudiobooks(for: licenseUrl)
      }
      lcpAudiobooks?.cancelPrefetch()
    }
#endif
  }
  
  // MARK: - Book State Binding
  
  private func bindRegistryState() {
    registry
      .bookStatePublisher
      .filter { $0.0 == self.book.identifier }
      .map { $0.1 }
      .receive(on: RunLoop.main) // Use RunLoop.main to avoid "Publishing changes during view updates"
      .sink { [weak self] newState in
        guard let self else { return }
        let updatedBook = registry.book(forIdentifier: book.identifier) ?? book
        let registryState = registry.state(for: book.identifier)
        
        // Always update book from registry - it has authoritative data including loan duration
        // after borrowing completes. The old optimization (only update if identifier/title changed)
        // was too aggressive and missed availability data changes needed for the HalfSheet.
        self.book = updatedBook
        
        // If we are in a local returning override, hold it until unregistered
        if let override = self.localBookStateOverride, override == .returning, registryState != .unregistered {
          return
        }
        self.bookState = registryState
        
        // Clear processing buttons based on state transitions
        switch registryState {
        case .unregistered:
          // Ensure UI is not left in a managing/processing state after returning
          self.isManagingHold = false
          self.showHalfSheet = false
          self.processingButtons.remove(.returning)
          self.processingButtons.remove(.cancelHold)
          self.processingButtons.remove(.return)
          self.processingButtons.remove(.remove)
          
        case .downloading:
          // Download started - clear download-related processing buttons
          self.processingButtons.remove(.download)
          self.processingButtons.remove(.get)
          self.processingButtons.remove(.retry)
          
        case .downloadFailed:
          // Download failed - clear download-related processing buttons
          self.processingButtons.remove(.download)
          self.processingButtons.remove(.get)
          self.processingButtons.remove(.retry)
          // Don't auto-close the HalfSheet on downloadFailed - the HalfSheet will update
          // to show retry/cancel buttons. Auto-closing causes a race condition with the
          // error alert presentation, resulting in the alert being auto-dismissed.
          
        case .downloadSuccessful, .used:
          // Download completed - clear all download-related processing and dismiss half sheet
          self.processingButtons.remove(.download)
          self.processingButtons.remove(.get)
          self.processingButtons.remove(.retry)
          self.showHalfSheet = false
          
        case .holding:
          // Hold placed - clear reserve button and dismiss half sheet
          self.processingButtons.remove(.reserve)
          self.processingButtons.remove(.get)
          self.showHalfSheet = false
          
        default:
          break
        }
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
    
    // Avoid general download center change notifications; we already subscribe to fine-grained progress and registry state publishers
    
    downloadCenter.downloadProgressPublisher
      .filter { $0.0 == self.book.identifier }
      .map { $0.1 }
      .assign(to: &$downloadProgress)
  }

  private func computeButtonState(book: TPPBook, state: TPPBookState, isManagingHold: Bool) -> BookButtonState {
    let availability = book.defaultAcquisition?.availability
    // Only count download/borrow-related processing, not return processing
    let downloadRelatedButtons: Set<BookButtonType> = [.download, .get, .retry, .reserve]
    let isProcessingDownload = state == .downloading || processingButtons.intersection(downloadRelatedButtons).count > 0
    if case .holding = state, isManagingHold { return .managingHold }
    return BookButtonMapper.map(
      registryState: state,
      availability: availability,
      isProcessingDownload: isProcessingDownload
    )
  }

  private func setupStableButtonState() {
    // Note: We still observe $isProcessing to trigger updates when processingButtons changes,
    // even though the value itself isn't used in computeButtonState anymore
    Publishers.CombineLatest4($book, $bookState, $isManagingHold, $isProcessing)
      .map { [weak self] book, state, isManaging, _ in
        self?.computeButtonState(book: book, state: state, isManagingHold: isManaging) ?? .unsupported
      }
      .removeDuplicates()
      // Use throttle instead of debounce - throttle emits immediately on first value,
      // then emits the latest value after the interval. Debounce waits for silence.
      .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
      .assign(to: &self.$stableButtonState)
  }
  
  @objc func handleBookRegistryChange(_ notification: Notification) {
    let updatedBook = registry.book(forIdentifier: book.identifier) ?? book
    // Always update book from registry - it has authoritative data including loan duration
    // after borrowing completes
    DispatchQueue.main.async {
      self.book = updatedBook
    }
  }
  
  func selectRelatedBook(_ newBook: TPPBook) {
    guard newBook.identifier != book.identifier else { return }
    Task { @MainActor in
      self.book = newBook
      self.bookState = registry.state(for: newBook.identifier)
      self.fetchRelatedBooks()
    }
  }
  
  // MARK: - Notifications
  
  @objc func handleDownloadStateDidChange(_ notification: Notification) {
    Task { @MainActor in
      self.downloadProgress = downloadCenter.downloadProgress(for: book.identifier)
      let info = downloadCenter.downloadInfo(forBookIdentifier: book.identifier)
      if let rights = info?.rightsManagement, rights != .unknown {
        if bookState != .downloading && bookState != .downloadSuccessful {
          self.bookState = registry.state(for: book.identifier)
        }
        #if LCP
        self.prefetchLCPStreamingIfPossible()
        #endif
      }
    }
  }
  
  // MARK: - Related Books
  
  func fetchRelatedBooks() {
    guard let url = book.relatedWorksURL else { return }
    
    isLoadingRelatedBooks = true
    relatedBooksByLane = [:]
    
    TPPOPDSFeed.withURL(url, shouldResetCache: false, useTokenIfAvailable: TPPUserAccount.sharedAccount().hasAdobeToken()) { [weak self] feed, _ in
      guard let self else { return }
      
      DispatchQueue.main.async {
        if feed?.type == .acquisitionGrouped {
          var groupTitleToBooks: [String: [TPPBook]] = [:]
          var groupTitleToMoreURL: [String: URL?] = [:]
          if let entries = feed?.entries as? [TPPOPDSEntry] {
            for entry in entries {
              guard let group = entry.groupAttributes else { continue }
              let groupTitle = group.title ?? ""
              if let b = CatalogViewModel.makeBook(from: entry) {
                groupTitleToBooks[groupTitle, default: []].append(b)
                if groupTitleToMoreURL[groupTitle] == nil { groupTitleToMoreURL[groupTitle] = group.href }
              }
            }
          }
          self.createRelatedBooksCells(groupedBooks: groupTitleToBooks, moreURLs: groupTitleToMoreURL)
        } else {
          self.isLoadingRelatedBooks = false
        }
      }
    }
  }
  
  private func createRelatedBooksCells(groupedBooks: [String: [TPPBook]], moreURLs: [String: URL?]) {
    var lanesMap = [String: BookLane]()
    for (title, books) in groupedBooks {
      let lane = BookLane(title: title, books: books, subsectionURL: moreURLs[title] ?? nil)
      lanesMap[title] = lane
    }
    
    if let author = book.authors, !author.isEmpty {
      if let authorLane = lanesMap.first(where: { $0.value.books.contains(where: { $0.authors?.contains(author) ?? false }) }) {
        lanesMap.removeValue(forKey: authorLane.key)
        var reorderedBooks = [String: BookLane]()
        reorderedBooks[authorLane.key] = authorLane.value
        reorderedBooks.merge(lanesMap) { _, new in new }
        lanesMap = reorderedBooks
      }
    }
    
    DispatchQueue.main.async {
      self.relatedBooksByLane = lanesMap
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
    guard !isProcessing(for: button) else { 
      Log.debug(#file, "Button \(button) is already processing, ignoring tap")
      return 
    }
    processingButtons.insert(button)
    
    switch button {
    case .reserve:
      didSelectReserve(for: book) { [weak self] in
        self?.removeProcessingButton(button)
        self?.showHalfSheet = false
      }
      
    case .return, .remove, .returning, .cancelHold:
      // Set state to returning for visual feedback
      bookState = .returning
      // Actually perform the return
      didSelectReturn(for: book) {
        self.removeProcessingButton(button)
        self.showHalfSheet = false
        self.isManagingHold = false
      }
      
    case .download, .get, .retry:
      self.downloadProgress = 0
      didSelectDownload(for: book)
      // Don't remove processing here - will be removed when state changes to .downloading or .downloadFailed
      
    case .read, .listen:
      didSelectRead(for: book) {
        self.removeProcessingButton(button)
      }
      
    case .cancel:
      didSelectCancel()
      // Remove after a short delay to show feedback
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.removeProcessingButton(button)
      }
      
    case .sample, .audiobookSample:
      didSelectPlaySample(for: book) {
        self.removeProcessingButton(button)
      }
      
    case .close:
      break
      
    case .manageHold:
      isManagingHold = true
      bookState = .holding
      break
    }
  }
  
  private func removeProcessingButton(_ button: BookButtonType) {
    self.processingButtons.remove(button)
  }
  
  func isProcessing(for button: BookButtonType) -> Bool {
    processingButtons.contains(button)
  }
  
  // MARK: - Authentication Helper
  
  /// Ensures authentication document is loaded and handles sign-in if needed.
  private func ensureAuthAndExecute(_ action: @escaping () -> Void) {
    let businessLogic = TPPSignInBusinessLogic(
      libraryAccountID: AccountsManager.shared.currentAccount?.uuid ?? "",
      libraryAccountsProvider: AccountsManager.shared,
      urlSettingsProvider: TPPSettings.shared,
      bookRegistry: TPPBookRegistry.shared,
      bookDownloadsCenter: MyBooksDownloadCenter.shared,
      userAccountProvider: TPPUserAccount.self,
      uiDelegate: nil,
      drmAuthorizer: nil
    )
    
    businessLogic.ensureAuthenticationDocumentIsLoaded { [weak self] (success: Bool) in
      DispatchQueue.main.async {
        guard let self = self else { return }
        
        let account = TPPUserAccount.sharedAccount()
        if account.needsAuth && !account.hasCredentials() {
          self.showHalfSheet = false
          SignInModalPresenter.presentSignInModalForCurrentAccount { [weak self] in
            guard let self else { return }
            // Only proceed if user successfully logged in, not if they cancelled
            guard TPPUserAccount.sharedAccount().hasCredentials() else {
              Log.info(#file, "Sign-in cancelled or failed, not proceeding with action")
              // Clear any processing state for download-related buttons
              self.processingButtons.remove(.download)
              self.processingButtons.remove(.get)
              self.processingButtons.remove(.retry)
              self.processingButtons.remove(.reserve)
              return
            }
            action()
          }
          return
        }
        action()
      }
    }
  }
  
  // MARK: - Download/Return/Cancel
  
  func didSelectDownload(for book: TPPBook) {
    self.downloadProgress = 0
    ensureAuthAndExecute { [weak self] in
      self?.startDownloadAfterAuth(book: book)
    }
  }

  private func startDownloadAfterAuth(book: TPPBook) {
    bookState = .downloading
    showHalfSheet = true
    downloadCenter.startDownload(for: book)
  }

  func didSelectReserve(for book: TPPBook, completion: (() -> Void)? = nil) {
    ensureAuthAndExecute { [weak self] in
      guard let self = self else { 
        completion?()
        return 
      }
      Task {
        do {
          _ = try await self.downloadCenter.borrowAsync(book, attemptDownload: false)
        } catch {
          Log.error(#file, "Failed to borrow book: \(error.localizedDescription)")
        }
        await MainActor.run {
          completion?()
        }
      }
    }
  }
  
  func didSelectCancel() {
    downloadCenter.cancelDownload(for: book.identifier)
    self.downloadProgress = 0
  }
  
  func didSelectReturn(for book: TPPBook, completion: (() -> Void)?) {
    processingButtons.insert(.returning)
    downloadCenter.returnBook(withIdentifier: book.identifier) { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.bookState = .unregistered
        self.processingButtons.remove(.returning)
        completion?()
      }
    }
  }
  
  // MARK: - Reading
  
  @MainActor
  func didSelectRead(for book: TPPBook, completion: (() -> Void)?) {
    ensureAuthAndExecute { [weak self] in
      Task { @MainActor in
        guard let self = self else { return }
#if FEATURE_DRM_CONNECTOR
        let user = TPPUserAccount.sharedAccount()
        
        if user.hasCredentials() {
          if user.hasAuthToken() {
            self.openBook(book, completion: completion)
            return
          } else if AdobeCertificate.isDRMAvailable &&
                      !AdobeDRMService.shared.isUserAuthorized(user.userID, deviceID: user.deviceID) {
            let reauthenticator = TPPReauthenticator()
            reauthenticator.authenticateIfNeeded(user, usingExistingCredentials: true) {
              Task { @MainActor in
                // Only proceed if user successfully re-authenticated
                guard user.hasCredentials() else {
                  completion?()
                  return
                }
                self.openBook(book, completion: completion)
              }
            }
            return
          }
        }
#endif
        self.openBook(book, completion: completion)
      }
    }
  }
  
  @MainActor
  func openBook(_ book: TPPBook, completion: (() -> Void)?) {
    Log.debug(#file, "🎬 [OPEN BOOK] User requested to open book: \(book.title) (ID: \(book.identifier))")
    TPPCirculationAnalytics.postEvent("open_book", withBook: book)
    
    let resolvedBook = registry.book(forIdentifier: book.identifier) ?? book
    let contentType = resolvedBook.defaultBookContentType
    
    Log.debug(#file, "  Content type determined: \(TPPBookContentTypeConverter.stringValue(of: contentType))")
    Log.debug(#file, "  Distributor: \(resolvedBook.distributor ?? "nil")")

    switch contentType {
    case .epub:
      Log.debug(#file, "  → Opening as EPUB")
      processingButtons.removeAll()
      presentEPUB(resolvedBook)
    case .pdf:
      Log.debug(#file, "  → Opening as PDF")
      processingButtons.removeAll()
      presentPDF(resolvedBook)
    case .audiobook:
      Log.debug(#file, "  → Opening as AUDIOBOOK")
      openAudiobook(resolvedBook) { [weak self] in
        DispatchQueue.main.async {
          self?.processingButtons.removeAll()
          completion?()
        }
      }
    default:
      Log.error(#file, "  ❌ UNSUPPORTED CONTENT TYPE - showing error to user")
      processingButtons.removeAll()
      presentUnsupportedItemError()
    }
  }
  
  @MainActor private func presentEPUB(_ book: TPPBook) {
    BookService.open(book)
  }
  
  @MainActor private func presentPDF(_ book: TPPBook) {
    BookService.open(book)
  }
  
  // MARK: - Audiobook Opening
  
  func openAudiobook(_ book: TPPBook, completion: (() -> Void)? = nil) {
    BookService.open(book, onFinish: completion)
  }
  
  
  private func getLCPLicenseURL(for book: TPPBook) -> URL? {
#if LCP
    guard let bookFileURL = downloadCenter.fileUrl(for: book.identifier) else {
      return nil
    }
    
    let licenseURL = bookFileURL.deletingPathExtension().appendingPathExtension("lcpl")
    
    if FileManager.default.fileExists(atPath: licenseURL.path) {
      return licenseURL
    }
    
    return nil
#else
    return nil
#endif
  }

#if LCP
  nonisolated static func lcpLicenseURL(forBookIdentifier identifier: String) -> URL? {
    guard let bookFileURL = MyBooksDownloadCenter.shared.fileUrl(for: identifier) else {
      return nil
    }
    let licenseURL = bookFileURL.deletingPathExtension().appendingPathExtension("lcpl")
    return FileManager.default.fileExists(atPath: licenseURL.path) ? licenseURL : nil
  }
#endif
  

  

  

#if LCP
  private func prefetchLCPStreamingIfPossible() {
    guard !didPrefetchLCPStreaming, LCPAudiobooks.canOpenBook(book), let licenseUrl = Self.lcpLicenseURL(forBookIdentifier: bookIdentifier) else { return }
    if let localURL = downloadCenter.fileUrl(for: bookIdentifier), FileManager.default.fileExists(atPath: localURL.path) {
      return
    }
    
    guard let lcpAudiobooks = LCPAudiobooks(for: licenseUrl) else { return }

    didPrefetchLCPStreaming = true
    lcpAudiobooks.startPrefetch()
  }
#endif
  
  
  // MARK: - Samples
  
  func didSelectPlaySample(for book: TPPBook, completion: (() -> Void)?) {
    guard !isProcessingSample else { return }
    isProcessingSample = true
    
    if book.defaultBookContentType == .audiobook {
      if book.sampleAcquisition?.type == "text/html" {
        SamplePreviewManager.shared.close()
        presentWebView(book.sampleAcquisition?.hrefURL)
        isProcessingSample = false
        completion?()
      } else {

        SamplePreviewManager.shared.toggle(for: book)
        isProcessingSample = false
        completion?()
      }
    } else {
      SamplePreviewManager.shared.close()
      EpubSampleFactory.createSample(book: book) { sampleURL, error in
        DispatchQueue.main.async {
          if let error = error {
            Log.debug("Sample generation error for \(book.title): \(error.localizedDescription)", "")
          } else if let sampleWebURL = sampleURL as? EpubSampleWebURL {
            self.presentWebView(sampleWebURL.url)
          } else if let sampleURL = sampleURL?.url {
            // Check if this is an EPUB sample
            let isEpubSample = book.sample?.type == .contentTypeEpubZip
            
            if isEpubSample {
              // Use Readium EPUB reader for EPUB samples
              ReaderService.shared.openSample(book, url: sampleURL)
            } else {
              // Use WebKit for HTML/web samples
              let web = BundledHTMLViewController(fileURL: sampleURL, title: book.title)
              if let top = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() {
                top.present(web, animated: true)
              }
            }
          }
          self.isProcessingSample = false
          completion?()
        }
      }
    }
  }
  
  private func presentWebView(_ url: URL?) {
    guard let url = url else { return }
    let webController = BundledHTMLViewController(
      fileURL: url,
      title: AccountsManager.shared.currentAccount?.name ?? ""
    )
    
    if let top = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() {
      top.present(webController, animated: true)
    }
  }
  
  
  // MARK: - Error Alerts
  
  private func presentCorruptedItemError() {
    // Log the error before presenting
    TPPErrorLogger.logError(
      withCode: .epubDecodingError,
      summary: "Corrupted EPUB item - cannot open book",
      metadata: [
        "book_id": book.identifier,
        "book_title": book.title,
        "distributor": book.distributor ?? "unknown"
      ]
    )
    
    let alert = UIAlertController(
      title: Strings.Error.epubNotValidError,
      message: Strings.Error.epubNotValidError,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
  
  private func presentUnsupportedItemError() {
    Log.error(#file, "⚠️ [UNSUPPORTED ITEM] Presenting unsupported item error")
    Log.error(#file, "  Book: \(book.title) (ID: \(book.identifier))")
    Log.error(#file, "  Distributor: \(book.distributor ?? "nil")")
    Log.error(#file, "  Content type: \(TPPBookContentTypeConverter.stringValue(of: book.defaultBookContentType))")
    Log.error(#file, "  All acquisitions:")
    for (index, acquisition) in book.acquisitions.enumerated() {
      Log.error(#file, "    \(index + 1). type=\(acquisition.type), relation=\(acquisition.relation)")
    }
    
    // Log the error before presenting
    TPPErrorLogger.logError(
      withCode: .unexpectedFormat,
      summary: "Unsupported book format",
      metadata: [
        "book_id": book.identifier,
        "book_title": book.title,
        "distributor": book.distributor ?? "unknown",
        "content_type": TPPBookContentTypeConverter.stringValue(of: book.defaultBookContentType),
        "all_acquisitions": book.acquisitions.map { "type=\($0.type), relation=\($0.relation)" }.joined(separator: "; ")
      ]
    )
    
    let alert = UIAlertController(
      title: Strings.Error.formatNotSupportedError,
      message: Strings.Error.formatNotSupportedError,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
  
  private func presentDRMKeyError(_ error: Error) {
    // Log DRM errors
    TPPErrorLogger.logError(
      error,
      summary: "DRM key error - cannot decrypt content",
      metadata: [
        "book_id": book.identifier,
        "book_title": book.title,
        "error_description": error.localizedDescription
      ]
    )
    
    let alert = UIAlertController(title: "DRM Error", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
}

extension BookDetailViewModel {
  public func scheduleTimer() {
    timer?.cancel()
    timer = nil
    
    let queue = DispatchQueue(label: "com.palace.pollAudiobookLocation", qos: .background, attributes: .concurrent)
    timer = DispatchSource.makeTimerSource(queue: queue)
    
    timer?.schedule(deadline: .now() + kTimerInterval, repeating: kTimerInterval)
    
    timer?.setEventHandler { [weak self] in
      self?.pollAudiobookReadingLocation()
    }
    
    timer?.resume()
  }
  @objc public func pollAudiobookReadingLocation() {
    // Position polling is now handled by AudiobookPlaybackModel in BookService
    // This legacy polling can interfere with the new system, so disable it
    timer?.cancel()
    timer = nil
  }
}

extension BookDetailViewModel {
  func chooseLocalLocation(localPosition: TrackPosition?, remotePosition: TrackPosition?, serverUpdateDelay: TimeInterval, operation: @escaping (TrackPosition) -> Void) {
    let remoteLocationIsNewer: Bool
    
    if let localPosition = localPosition, let remotePosition = remotePosition {
      remoteLocationIsNewer = String.isDate(remotePosition.lastSavedTimeStamp, moreRecentThan: localPosition.lastSavedTimeStamp, with: serverUpdateDelay)
    } else {
      remoteLocationIsNewer = localPosition == nil && remotePosition != nil
    }
    
    if let remotePosition = remotePosition,
       remotePosition.description != localPosition?.description,
       remoteLocationIsNewer {
      requestSyncWithCompletion { shouldSync in
        let location = shouldSync ? remotePosition : (localPosition ?? remotePosition)
        operation(location)
      }
    } else if let localPosition = localPosition {
      operation(localPosition)
    } else if let remotePosition = remotePosition {
      operation(remotePosition)
    }
  }
  
  func requestSyncWithCompletion(completion: @escaping (Bool) -> Void) {
    DispatchQueue.main.async {
      let title = LocalizedStrings.syncListeningPositionAlertTitle
      let message = LocalizedStrings.syncListeningPositionAlertBody
      let moveTitle = LocalizedStrings.move
      let stayTitle = LocalizedStrings.stay
      
      let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
      
      let moveAction = UIAlertAction(title: moveTitle, style: .default) { _ in
        completion(true)
      }
      
      let stayAction = UIAlertAction(title: stayTitle, style: .cancel) { _ in
        completion(false)
      }
      
      alertController.addAction(moveAction)
      alertController.addAction(stayAction)
      
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alertController, viewController: nil, animated: true, completion: nil)
    }
  }
  
  static func presentEndOfBookAlert(for book: TPPBook) {
    let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
      forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
      allowedRelations: [.borrow, .generic],
      acquisitions: book.acquisitions
    )
    
    if paths.count > 0 {
      let alert = TPPReturnPromptHelper.audiobookPrompt { returnWasChosen in
        if returnWasChosen {
          NavigationCoordinatorHub.shared.coordinator?.pop()
          MyBooksDownloadCenter.shared.returnBook(withIdentifier: book.identifier)
        }
        TPPAppStoreReviewPrompt.presentIfAvailable()
      }
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
    } else {
      TPPAppStoreReviewPrompt.presentIfAvailable()
    }
  }
  
  private func presentEndOfBookAlert() {
    BookDetailViewModel.presentEndOfBookAlert(for: book)
  }
}

// MARK: – BookButtonProvider
extension BookDetailViewModel: BookButtonProvider {
  var buttonTypes: [BookButtonType] {
    buttonState.buttonTypes(book: book)
  }
}

// MARK: - LCP Streaming Enhancement
#if LCP

private extension BookDetailViewModel {
  /// Extract publication URL from LCPAudiobooks instance
  func getPublicationUrl(from lcpAudiobooks: LCPAudiobooks) -> URL? {
    
    guard let licenseUrl = getLCPLicenseURL(for: book),
          let license = TPPLCPLicense(url: licenseUrl),
          let publicationLink = license.firstLink(withRel: .publication),
          let href = publicationLink.href,
          let publicationUrl = URL(string: href) else {
      return nil
    }
    
    return publicationUrl
  }
}
#endif


extension BookDetailViewModel: HalfSheetProvider {}
