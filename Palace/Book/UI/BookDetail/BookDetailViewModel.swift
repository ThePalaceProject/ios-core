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
  
  var isFullSize: Bool { UIDevice.current.isIpad }
  
  @Published var processingButtons: Set<BookButtonType> = [] {
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
  
  @objc init(book: TPPBook) {
    self.book = book
    self.registry = TPPBookRegistry.shared
    self.bookState = registry.state(for: book.identifier)
    self.bookIdentifier = book.identifier
    self.stableButtonState = self.computeButtonState(book: book, state: self.bookState, isManagingHold: self.isManagingHold, isProcessing: self.isProcessing)
    
    bindRegistryState()
    setupStableButtonState()
    setupObservers()
    self.downloadProgress = downloadCenter.downloadProgress(for: book.identifier)
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
      .receive(on: DispatchQueue.main)
      .sink { [weak self] newState in
        guard let self else { return }
        let updatedBook = registry.book(forIdentifier: book.identifier) ?? book
        let registryState = registry.state(for: book.identifier)

        self.book = updatedBook
        // If we are in a local returning override, hold it until unregistered
        if let override = self.localBookStateOverride, override == .returning, registryState != .unregistered {
          return
        }
        self.bookState = registryState
        if registryState == .unregistered {
          // Ensure UI is not left in a managing/processing state after returning
          self.isManagingHold = false
          self.showHalfSheet = false
          self.processingButtons.remove(.returning)
          self.processingButtons.remove(.cancelHold)
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
      .receive(on: DispatchQueue.main)
      .assign(to: &$downloadProgress)
  }

  private func computeButtonState(book: TPPBook, state: TPPBookState, isManagingHold: Bool, isProcessing: Bool) -> BookButtonState {
    let availability = book.defaultAcquisition?.availability
    let isProcessingDownload = isProcessing || state == .downloading
    if case .holding = state, isManagingHold { return .managingHold }
    return BookButtonMapper.map(
      registryState: state,
      availability: availability,
      isProcessingDownload: isProcessingDownload
    )
  }

  private func setupStableButtonState() {
    Publishers.CombineLatest4($book, $bookState, $isManagingHold, $isProcessing)
      .map { [weak self] book, state, isManaging, isProcessing in
        self?.computeButtonState(book: book, state: state, isManagingHold: isManaging, isProcessing: isProcessing) ?? .unsupported
      }
      .removeDuplicates()
      .debounce(for: .milliseconds(180), scheduler: DispatchQueue.main)
      .receive(on: DispatchQueue.main)
      .assign(to: &self.$stableButtonState)
  }
  
  @objc func handleBookRegistryChange(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let updatedBook = registry.book(forIdentifier: book.identifier) ?? book
      self.book = updatedBook
    }
  }
  
  func selectRelatedBook(_ newBook: TPPBook) {
    guard newBook.identifier != book.identifier else { return }
    book = newBook
    bookState = registry.state(for: newBook.identifier)
    fetchRelatedBooks()
  }
  
  // MARK: - Notifications
  
  @objc func handleDownloadStateDidChange(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
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
      didSelectReserve(for: book)
      removeProcessingButton(button)
      showHalfSheet = false
    case .return, .remove:
      bookState = .returning
      removeProcessingButton(button)
      
    case .returning, .cancelHold:
      // didSelectReturn will guard against duplicate requests using processingButtons
      didSelectReturn(for: book) {
        self.removeProcessingButton(button)
        self.showHalfSheet = false
        self.isManagingHold = false
      }
      
    case .download, .get, .retry:
      self.downloadProgress = 0
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
  
  // MARK: - Download/Return/Cancel
  
  func didSelectDownload(for book: TPPBook) {
    self.downloadProgress = 0
    let account = TPPUserAccount.sharedAccount()
    if account.needsAuth && !account.hasCredentials() {
      showHalfSheet = false
      TPPAccountSignInViewController.requestCredentials { [weak self] in
        guard let self else { return }
        self.startDownloadAfterAuth(book: book)
      }
      return
    }
    startDownloadAfterAuth(book: book)
  }

  private func startDownloadAfterAuth(book: TPPBook) {
    bookState = .downloading
    showHalfSheet = true
    downloadCenter.startDownload(for: book)
  }

  func didSelectReserve(for book: TPPBook) {
    let account = TPPUserAccount.sharedAccount()
    if account.needsAuth && !account.hasCredentials() {
      showHalfSheet = false
      TPPAccountSignInViewController.requestCredentials { [weak self] in
        guard let self else { return }
        self.downloadCenter.startBorrow(for: book, attemptDownload: false)
      }
      return
    }
    downloadCenter.startBorrow(for: book, attemptDownload: false)
  }
  
  func didSelectCancel() {
    downloadCenter.cancelDownload(for: book.identifier)
    self.downloadProgress = 0
  }
  
  func didSelectReturn(for book: TPPBook, completion: (() -> Void)?) {
    // Prevent multiple return requests and UI loops
    processingButtons.insert(.returning)
    downloadCenter.returnBook(withIdentifier: book.identifier) { [weak self] in
      guard let self else { return }
      self.bookState = .unregistered
      self.processingButtons.remove(.returning)
      completion?()
    }
  }
  
  // MARK: - Reading
  
  @MainActor
  func didSelectRead(for book: TPPBook, completion: (() -> Void)?) {
    let account = TPPUserAccount.sharedAccount()
    if account.needsAuth && !account.hasCredentials() {
      TPPAccountSignInViewController.requestCredentials { [weak self] in
        Task { @MainActor in
          self?.openBook(book, completion: completion)
        }
      }
      return
    }
#if FEATURE_DRM_CONNECTOR
    let user = TPPUserAccount.sharedAccount()
    
    if user.hasCredentials() {
      if user.hasAuthToken() {
        openBook(book, completion: completion)
        return
      } else if !(AdobeCertificate.defaultCertificate?.hasExpired ?? false) &&
                  !NYPLADEPT.sharedInstance().isUserAuthorized(user.userID, withDevice: user.deviceID) {
        let reauthenticator = TPPReauthenticator()
        reauthenticator.authenticateIfNeeded(user, usingExistingCredentials: true) {
          Task { @MainActor in
            self.openBook(book, completion: completion)
          }
        }
        return
      }
    }
#endif
    openBook(book, completion: completion)
  }
  
  @MainActor
  func openBook(_ book: TPPBook, completion: (() -> Void)?) {
    TPPCirculationAnalytics.postEvent("open_book", withBook: book)
    
    let resolvedBook = registry.book(forIdentifier: book.identifier) ?? book

    switch resolvedBook.defaultBookContentType {
    case .epub:
      processingButtons.removeAll()
      presentEPUB(resolvedBook)
    case .pdf:
      processingButtons.removeAll()
      presentPDF(resolvedBook)
    case .audiobook:
      openAudiobook(resolvedBook) { [weak self] in
        DispatchQueue.main.async {
          self?.processingButtons.removeAll()
          completion?()
        }
      }
    default:
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
        presentWebView(book.sampleAcquisition?.hrefURL)
        isProcessingSample = false
        completion?()
      } else {
        // Use centralized preview manager for audiobooks
        SamplePreviewManager.shared.toggle(for: book)
        isProcessingSample = false
        completion?()
      }
    } else {
      EpubSampleFactory.createSample(book: book) { sampleURL, error in
        DispatchQueue.main.async {
          if let error = error {
            Log.debug("Sample generation error for \(book.title): \(error.localizedDescription)", "")
          } else if let sampleWebURL = sampleURL as? EpubSampleWebURL {
            self.presentWebView(sampleWebURL.url)
          } else if let sampleURL = sampleURL?.url {
            let web = BundledHTMLViewController(fileURL: sampleURL, title: book.title)
            if let top = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() {
              top.present(web, animated: true)
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
    let alert = UIAlertController(
      title: Strings.Error.epubNotValidError,
      message: Strings.Error.epubNotValidError,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
  
  private func presentUnsupportedItemError() {
    let alert = UIAlertController(
      title: Strings.Error.formatNotSupportedError,
      message: Strings.Error.formatNotSupportedError,
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
  
  private func presentEndOfBookAlert() {
    let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
      forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
      allowedRelations: [.borrow, .generic],
      acquisitions: book.acquisitions
    )
    
    if paths.count > 0 {
      let alert = TPPReturnPromptHelper.audiobookPrompt { [weak self] returnWasChosen in
        guard let self else { return }
        
        if returnWasChosen {
          NavigationCoordinatorHub.shared.coordinator?.pop()
          self.didSelectReturn(for: self.book, completion: nil)
        }
        TPPAppStoreReviewPrompt.presentIfAvailable()
      }
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
    } else {
      TPPAppStoreReviewPrompt.presentIfAvailable()
    }
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
