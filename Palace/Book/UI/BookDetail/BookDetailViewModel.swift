import Combine
import SwiftUI
import PalaceAudiobookToolkit

struct BookLane {
  let title: String
  let books: [TPPBook]
  let subsectionURL: URL?
}

class BookDetailViewModel: HalfSheetProvider, ObservableObject {
  /// The book model.
  @Published var book: TPPBook

  /// The registry state, e.g. `unregistered`, `downloading`, `downloadSuccessful` etc.
  @Published var bookState: TPPBookState

  /// Misc published fields for UI updates.
  @Published var bookmarks: [TPPReadiumBookmark] = []
  @Published var showSampleToolbar = false
  @Published var downloadProgress: Double = 0.0

  @Published var buttonState: BookButtonState = .unsupported
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
  let registry: TPPBookRegistryProvider
  let downloadCenter = MyBooksDownloadCenter.shared
  private var cancellables = Set<AnyCancellable>()

  private var audiobookViewController: UIViewController?
  private var audiobookManager: DefaultAudiobookManager?
  private var audiobookPlayer: AudiobookPlayer?
  private var audiobookBookmarkBusinessLogic: AudiobookBookmarkBusinessLogic?
  private var timer: DispatchSourceTimer?
  private var previousPlayheadOffset: TimeInterval = 0


  // MARK: - Initializer
  @objc init(book: TPPBook) {
    self.book = book
    self.registry = TPPBookRegistry.shared
    self.bookState = registry.state(for: book.identifier)

    bindRegistryState()
    buttonState = BookButtonState(book) ?? BookButtonState.stateForAvailability(self.book.defaultAcquisition?.availability) ?? .unsupported
    setupObservers()
    self.downloadProgress = downloadCenter.downloadProgress(for: book.identifier)
  }

  deinit {
    timer?.cancel()
    timer = nil
  }

  // MARK: - Book State Binding

  /// Automatically updates `state` whenever `registry.bookStatePublisher` changes for this book.
  private func bindRegistryState() {
    (registry as? TPPBookRegistry)?
      .bookStatePublisher
      .filter { $0.0 == self.book.identifier }
      .map { $0.1 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] newState in
        guard let self = self else { return }
        self.bookState = newState
        self.determineButtonState()
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

  func selectRelatedBook(_ newBook: TPPBook) {
    guard newBook.identifier != book.identifier else { return }
    book = newBook
    determineButtonState()
    fetchRelatedBooks()
  }

  // MARK: - Notifications

  @objc func handleBookRegistryChange(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let newBook = registry.book(forIdentifier: book.identifier) ?? book
      self.book = newBook
      self.bookState = registry.state(for: book.identifier)
      determineButtonState()
    }
  }

  @objc func handleMyBooksDidChange(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.downloadProgress = downloadCenter.downloadProgress(for: book.identifier)
      let info = downloadCenter.downloadInfo(forBookIdentifier: book.identifier)
      if let rights = info?.rightsManagement, rights != .unknown {
        if bookState != .downloading && bookState != .downloadSuccessful {
          bookState = .downloading
        }
      }
    }
  }

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

  // MARK: - Create Related Books Cells
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
    }

    self.isLoadingRelatedBooks = false
  }

  // MARK: - Show More Books for Lane
  func showMoreBooksForLane(laneTitle: String) {
    guard let lane = relatedBooksByLane[laneTitle] else {
      return
    }

    if let subsectionURL = lane.subsectionURL {
      self.selectedBookURL = subsectionURL
    }
  }


  // MARK: - Button State Mapping

  /// Maps registry `state` to `buttonState` for simpler SwiftUI usage.
  private func determineButtonState() {
    let newState: BookButtonState

    switch bookState {
    case .unregistered:
      newState = BookButtonState.stateForAvailability(book.defaultAcquisition?.availability) ?? .canBorrow
    case .downloadNeeded:
      newState = .downloadNeeded
    case .downloading:
      newState = .downloadInProgress
    case .downloadSuccessful:
      newState = .downloadSuccessful
    case .holding:
      newState = .holding
    case .downloadFailed:
      newState = .downloadFailed
    case .used:
      newState = .used
    default:
      newState = .unsupported
    }

    if buttonState != newState {
      buttonState = newState
    }
  }

  // MARK: - Actions: Unified Handle

  func handleAction(for button: BookButtonType) {
    guard !isProcessing(for: button) else {
      return
    }

    processingButtons.insert(button)

    switch button {
    case .reserve:
      didSelectDownload(for: book)

      registry.setState(.holding, for: book.identifier)
      removeProcessingButton(button)
    case .return, .remove, .cancelHold:
      buttonState = .returning
      bookState = .returning
      self.removeProcessingButton(button)

    case .manageHold:
      buttonState = .managingHold
      bookState = .returning
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
    case .close:
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
          DispatchQueue.main.async {
            self.openBook(book, completion: completion)
          }
        }
        return
      }
    }
#endif
    openBook(book, completion: completion)
  }

  func openBook(_ book: TPPBook, completion: (() -> Void)?) {
    TPPCirculationAnalytics.postEvent("open_book", withBook: book)
    processingButtons.removeAll()

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

  func openAudiobook(_ book: TPPBook, completion: (() -> Void)? = nil) {
    guard let url = downloadCenter.fileUrl(for: book.identifier) else {
      presentCorruptedItemError()
      completion?()
      return
    }

#if LCP
    if LCPAudiobooks.canOpenBook(book) {
      let lcpAudiobooks = LCPAudiobooks(for: url)
      lcpAudiobooks?.contentDictionary { [weak self] dict, error in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if let error {
            self.presentUnsupportedItemError()
            completion?()
            return
          }

          guard let dict else {
            self.presentCorruptedItemError()
            completion?()
            return
          }

          var jsonDict = dict as? [String: Any] ?? [:]
          jsonDict["id"] = book.identifier
          self.openAudiobook(with: book, json: jsonDict, drmDecryptor: lcpAudiobooks, completion: completion)
        }
      }
      return
    }
#endif

    do {
      let data = try Data(contentsOf: url)
      guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        presentUnsupportedItemError()
        completion?()
        return
      }

#if FEATURE_OVERDRIVE
      if book.distributor == OverdriveDistributorKey {
        var overdriveJson = json
        overdriveJson["id"] = book.identifier
        openAudiobook(with: book, json: overdriveJson, drmDecryptor: nil, completion: completion)
        return
      }
#endif

      openAudiobook(with: book, json: json, drmDecryptor: nil, completion: completion)
    } catch {
      presentCorruptedItemError()
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

        self.launchAudiobook(book: book, audiobook: audiobook)
        completion?()
      }
    }
  }

  @MainActor private func launchAudiobook(book: TPPBook, audiobook: Audiobook) {
    var timeTracker: AudiobookTimeTracker?
    if let libraryId = AccountsManager.shared.currentAccount?.uuid, let timeTrackingURL = book.timeTrackingURL {
      timeTracker = AudiobookTimeTracker(libraryId: libraryId, bookId: book.identifier, timeTrackingUrl: timeTrackingURL)
    }

    let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""])

    audiobookManager = DefaultAudiobookManager(
      metadata: metadata,
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks),
      playbackTrackerDelegate: timeTracker
    )

    guard let audiobookManager else { return }

    audiobookBookmarkBusinessLogic = AudiobookBookmarkBusinessLogic(book: book)
    audiobookManager.bookmarkDelegate = audiobookBookmarkBusinessLogic
    audiobookPlayer = AudiobookPlayer(audiobookManager: audiobookManager, coverImagePublisher: book.$coverImage.eraseToAnyPublisher())


    TPPRootTabBarController.shared().pushViewController(audiobookPlayer!, animated: true)

    syncAudiobookLocation(for: book)
    scheduleTimer()
  }

  private func setupAudiobookPlayback(book: TPPBook, audiobook: Audiobook) {
    let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""])
    audiobookManager = DefaultAudiobookManager(
      metadata: metadata,
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
    )

    guard let audiobookManager else { return }

    audiobookBookmarkBusinessLogic = AudiobookBookmarkBusinessLogic(book: book)
    audiobookManager.bookmarkDelegate = audiobookBookmarkBusinessLogic

    let audiobookPlayer = AudiobookPlayer(audiobookManager: audiobookManager, coverImagePublisher: book.$coverImage.eraseToAnyPublisher())
    TPPRootTabBarController.shared().pushViewController(audiobookPlayer, animated: true)

    syncAudiobookLocation(for: book)

    scheduleTimer()
  }

  /// Syncs audiobook playback position from local or remote bookmarks
  private func syncAudiobookLocation(for book: TPPBook) {
    let localLocation = TPPBookRegistry.shared.location(forIdentifier: book.identifier)

    guard let dictionary = localLocation?.locationStringDictionary(),
          let localBookmark = AudioBookmark.create(locatorData: dictionary),
          let manager = audiobookManager,
          let localPosition = TrackPosition(
            audioBookmark: localBookmark,
            toc: manager.audiobook.tableOfContents.toc,
            tracks: manager.audiobook.tableOfContents.tracks
          ) else {
      return
    }

    audiobookManager?.audiobook.player.play(at: localPosition, completion: nil)

    TPPBookRegistry.shared.syncLocation(for: book) { [weak self] remoteBookmark in
      guard let remoteBookmark, let self, let audiobookManager else { return }

      let remotePosition = TrackPosition(
        audioBookmark: remoteBookmark,
        toc: audiobookManager.audiobook.tableOfContents.toc,
        tracks: audiobookManager.audiobook.tableOfContents.tracks
      )

      self.chooseLocalLocation(
        localPosition: localPosition,
        remotePosition: remotePosition,
        serverUpdateDelay: 300
      ) { position in
        DispatchQueue.main.async {
          self.audiobookManager?.audiobook.player.play(at: position, completion: nil)
        }
      }
    }
  }

  // MARK: - Samples

  func didSelectPlaySample(for book: TPPBook, completion: (() -> Void)?) {
    guard !isProcessingSample else { return }
    isProcessingSample = true

    if book.defaultBookContentType == .audiobook {
      if book.sampleAcquisition?.type == "text/html" {
        presentWebView(book.sampleAcquisition?.hrefURL)
        isProcessingSample = false
        completion?()
      } else if !isShowingSample {
        isShowingSample = true
        showSampleToolbar = true
        isProcessingSample = false
        completion?()
      }
      NotificationCenter.default.post(name: Notification.Name("ToggleSampleNotification"), object: self)
    } else {
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

    let root = TPPRootTabBarController.shared()
    let top = root?.topMostViewController
    top?.present(webController, animated: true)
  }

  // MARK: - Error Alerts

  private func presentCorruptedItemError() {
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

    guard let _ = self.audiobookViewController else {
      timer?.cancel()
      timer = nil
      self.audiobookManager = nil
      return
    }

    guard let currentTrackPosition = self.audiobookManager?.audiobook.player.currentTrackPosition else {
      return
    }

    let playheadOffset = currentTrackPosition.timestamp
    if self.previousPlayheadOffset != playheadOffset && playheadOffset > 0 {
      self.previousPlayheadOffset = playheadOffset

      DispatchQueue.global(qos: .background).async { [weak self] in
        guard let self = self else { return }

        let locationData = try? JSONEncoder().encode(currentTrackPosition.toAudioBookmark())
        let locationString = String(data: locationData ?? Data(), encoding: .utf8) ?? ""

        DispatchQueue.main.async {
          TPPBookRegistry.shared.setLocation(
            TPPBookLocation(locationString: locationString, renderer: "PalaceAudiobookToolkit"),
            forIdentifier: self.book.identifier
          )

          latestAudiobookLocation = (book: self.book.identifier, location: locationString)
        }
      }
    }
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
}

extension BookDetailViewModel: BookButtonProvider {
  var buttonTypes: [BookButtonType] {
    buttonState.buttonTypes(book: book)
  }
}
