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
  @Published var isManagingHold: Bool = false
  @Published var showHalfSheet = false
  
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
  
  private var audiobookViewController: UIViewController?
  private var audiobookManager: DefaultAudiobookManager?
  private var audiobookPlayer: AudiobookPlayer?
  private var audiobookBookmarkBusinessLogic: AudiobookBookmarkBusinessLogic?
  private var timer: DispatchSourceTimer?
  private var previousPlayheadOffset: TimeInterval = 0
  
  // MARK: – Computed Button State
  
  var buttonState: BookButtonState {
    let isDownloading = (bookState == .downloading)
    let avail = book.defaultAcquisition?.availability
    
    if case .holding = bookState, isManagingHold {
      return .managingHold
    }
    
#if LCP
    // For LCP audiobooks, show as ready if they can be opened (license can be fulfilled)
    if LCPAudiobooks.canOpenBook(book) {
      switch bookState {
      case .downloadNeeded:
        // LCP audiobooks can be "opened" to start license fulfillment
        // Log.debug(#file, "🎵 LCP audiobook downloadNeeded → showing downloadSuccessful")
        return .downloadSuccessful
      case .downloading:
        // Show as downloading while license fulfillment is in progress
        // Log.debug(#file, "🎵 LCP audiobook downloading → showing downloadInProgress")
        return BookButtonMapper.map(
          registryState: bookState,
          availability: avail,
          isProcessingDownload: isDownloading
        )
      case .downloadSuccessful, .used:
        // Already downloaded/fulfilled
        // Log.debug(#file, "🎵 LCP audiobook downloadSuccessful → showing LISTEN button")
        return .downloadSuccessful
      default:
        Log.debug(#file, "🎵 LCP audiobook other state: \(bookState)")
        break
      }
    }
#endif
    
    let mappedState = BookButtonMapper.map(
      registryState: bookState,
      availability: avail,
      isProcessingDownload: isDownloading
    )
    Log.debug(#file, "🎵 Default button mapping: \(bookState) → \(mappedState)")
    return mappedState
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
  
  private func bindRegistryState() {
    registry
      .bookStatePublisher
      .filter { $0.0 == self.book.identifier }
      .map { $0.1 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] newState in
        guard let self else { return }
        let updatedBook = registry.book(forIdentifier: book.identifier) ?? book
        let currentState = self.bookState
        let registryState = registry.state(for: book.identifier)
        
        Log.info(#file, "🎵 Publisher state change for \(book.identifier): \(currentState) → \(registryState)")
        Log.info(#file, "🎵 New button state will be: \(buttonState)")
        
        self.book = updatedBook
        self.bookState = registryState
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
      selector: #selector(handleDownloadStateDidChange(_:)),
      name: .TPPMyBooksDownloadCenterDidChange,
      object: nil
    )
    
    downloadCenter.downloadProgressPublisher
      .filter { $0.0 == self.book.identifier }
      .map { $0.1 }
      .receive(on: DispatchQueue.main)
      .assign(to: &$downloadProgress)
  }
  
  @objc func handleBookRegistryChange(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let updatedBook = registry.book(forIdentifier: book.identifier) ?? book
      let newState = registry.state(for: book.identifier)
      
      Log.info(#file, "🎵 Registry state change for \(book.identifier): \(bookState) → \(newState)")
      Log.info(#file, "🎵 Button state will be: \(buttonState)")
      
      self.book = updatedBook
      self.bookState = newState
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
      downloadCenter.startDownload(for: book)
      registry.setState(.holding, for: book.identifier)
      removeProcessingButton(button)
      showHalfSheet = false
    case .return, .remove:
      bookState = .returning
      removeProcessingButton(button)
      
    case .returning, .cancelHold:
      didSelectReturn(for: book) {
        self.showHalfSheet = false
        self.removeProcessingButton(button)
        self.bookState = .unregistered
        self.isManagingHold = false
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
      
    case .manageHold:
      isManagingHold = true
      bookState = .holding
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
    // First priority: Check if we have a local file already - verify file actually exists
    if let url = downloadCenter.fileUrl(for: book.identifier),
       FileManager.default.fileExists(atPath: url.path) {
      // File exists, proceed with normal flow
      Log.info(#file, "Opening LCP audiobook with local file: \(book.identifier)")
      openAudiobookWithLocalFile(book: book, url: url, completion: completion)
      return
    }
    
    // No local file - for LCP audiobooks, check for license-based streaming
#if LCP
    if LCPAudiobooks.canOpenBook(book) {
      // Check if we have license file for streaming
      if let licenseUrl = getLCPLicenseURL(for: book) {
        // Have license, open in streaming mode as fallback
        Log.info(#file, "Opening LCP audiobook in streaming mode: \(book.identifier)")
        openAudiobookUnified(book: book, licenseUrl: licenseUrl, completion: completion)
        return
      }
      
      // License not found yet - check if fulfillment is in progress
      if bookState == .downloadSuccessful {
        // Book is marked as ready but license not found - fulfillment may be in progress
        Log.info(#file, "License fulfillment may be in progress, waiting for completion: \(book.identifier)")
        waitForLicenseFulfillment(book: book, completion: completion)
        return
      }
      
      // No license yet, start fulfillment
      Log.info(#file, "No local file for LCP audiobook, starting license fulfillment: \(book.identifier)")
      Log.info(#file, "Expected LCP MIME type: application/vnd.readium.lcp.license.v1.0+json")
      if let acqURL = book.defaultAcquisition?.hrefURL {
        Log.info(#file, "Downloading LCP license from: \(acqURL.absoluteString)")
      }
      downloadCenter.startDownload(for: book)
      // Note: MyBooksDownloadCenter will set bookState to .downloadSuccessful when fulfillment completes
      completion?()
      return
    }
#endif
    
    presentCorruptedItemError()
    completion?()
  }
  
  private func getLCPLicenseURL(for book: TPPBook) -> URL? {
#if LCP
    // Check for license file in the same location as content files
    // License is stored as {hashedIdentifier}.lcpl in the content directory
    guard let bookFileURL = downloadCenter.fileUrl(for: book.identifier) else {
      return nil
    }
    
    // License has same path but .lcpl extension
    let licenseURL = bookFileURL.deletingPathExtension().appendingPathExtension("lcpl")
    
    if FileManager.default.fileExists(atPath: licenseURL.path) {
      Log.debug(#file, "Found LCP license at: \(licenseURL.path)")
      return licenseURL
    }
    
    Log.debug(#file, "No LCP license found at: \(licenseURL.path)")
    return nil
#else
    return nil
#endif
  }
  
  private func waitForLicenseFulfillment(book: TPPBook, completion: (() -> Void)? = nil, attempt: Int = 0) {
    let maxAttempts = 10 // Wait up to 10 seconds
    let retryDelay: TimeInterval = 1.0
    
    // Check if license file is now available
    if let licenseUrl = getLCPLicenseURL(for: book) {
      Log.info(#file, "License fulfillment completed, opening in streaming mode: \(book.identifier)")
      openAudiobookUnified(book: book, licenseUrl: licenseUrl, completion: completion)
      return
    }
    
    // If we've exceeded max attempts, show error
    if attempt >= maxAttempts {
      Log.error(#file, "Timeout waiting for license fulfillment after \(attempt) attempts")
      presentUnsupportedItemError()
      completion?()
      return
    }
    
    // Wait and retry
    Log.debug(#file, "License not ready yet, waiting... (attempt \(attempt + 1)/\(maxAttempts))")
    DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
      self?.waitForLicenseFulfillment(book: book, completion: completion, attempt: attempt + 1)
    }
  }
  
  private func openAudiobookUnified(book: TPPBook, licenseUrl: URL, completion: (() -> Void)?) {
#if LCP
    Log.info(#file, "Opening LCP audiobook for streaming: \(book.identifier)")
    Log.debug(#file, "License available at: \(licenseUrl.absoluteString)")
    
    // Get the publication URL from the license
    guard let license = TPPLCPLicense(url: licenseUrl),
          let publicationLink = license.firstLink(withRel: .publication),
          let href = publicationLink.href,
          let publicationUrl = URL(string: href) else {
      Log.error(#file, "Failed to extract publication URL from license")
      self.presentUnsupportedItemError()
      completion?()
      return
    }
    
    Log.info(#file, "Using publication URL for streaming: \(publicationUrl.absoluteString)")
    
    // Create LCPAudiobooks with the HTTP publication URL (this works since LCPAudiobooks supports HTTP URLs)
    guard let lcpAudiobooks = LCPAudiobooks(for: publicationUrl) else {
      Log.error(#file, "Failed to create LCPAudiobooks for streaming URL")
      self.presentUnsupportedItemError()
      completion?()
      return
    }
    
    // Use the same contentDictionary pattern as local files - this is the proven path!
    lcpAudiobooks.contentDictionary { [weak self] dict, error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        
        if let error {
          Log.error(#file, "Failed to get content dictionary for streaming: \(error)")
          self.presentUnsupportedItemError()
          completion?()
          return
        }
        
        guard let dict else {
          Log.error(#file, "No content dictionary returned for streaming")
          self.presentCorruptedItemError()
          completion?()
          return
        }
        
        // Use the exact same pattern as openAudiobookWithLocalFile
        var jsonDict = dict as? [String: Any] ?? [:]
        jsonDict["id"] = book.identifier
        
        Log.info(#file, "✅ Got content dictionary for streaming, opening with AudiobookFactory")
        self.openAudiobook(with: book, json: jsonDict, drmDecryptor: lcpAudiobooks, completion: completion)
      }
    }
#endif
  }
  
  /// Gets the publication manifest for streaming using Readium LCP service directly

  
  /// Extracts the publication URL from the license for use with LCPAudiobooks
  /// Since we already have the publication URL from parsing the license, we can store and reuse it
  private var cachedPublicationUrl: URL?
  
  private func getPublicationUrlFromManifest(_ manifest: [String: Any]) -> URL? {
    // Return the cached publication URL that we got from the license
    return cachedPublicationUrl
  }
  
  private func openAudiobookWithLocalFile(book: TPPBook, url: URL, completion: (() -> Void)?) {
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
        guard let self else { return }
        
        if let error {
          self.presentDRMKeyError(error)
          completion?()
          return
        }
        
        let manifestDecoder = Manifest.customDecoder()
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []) else {
          Log.error(#file, "❌ Failed to serialize manifest JSON")
          self.presentUnsupportedItemError()
          completion?()
          return
        }
        
        guard let manifest = try? manifestDecoder.decode(Manifest.self, from: jsonData) else {
          Log.error(#file, "❌ Failed to decode manifest from JSON")
          self.presentUnsupportedItemError()
          completion?()
          return
        }
        
        // DEBUG: Log which manifest we're actually using
        Log.info(#file, "✅ Manifest decoded successfully - contains \(manifest.readingOrder?.count ?? 0) reading order items")
        if let readingOrder = manifest.readingOrder {
          Log.debug(#file, "🔍 First 5 tracks: \(readingOrder.prefix(5).compactMap { $0.title })")
          Log.debug(#file, "🔍 Last 5 tracks: \(readingOrder.suffix(5).compactMap { $0.title })")
        }
        
        Log.info(#file, "✅ Creating audiobook with AudiobookFactory")
        
        // Use the original Readium manifest - no enhancement needed for proper Readium streaming
        
        guard let audiobook = AudiobookFactory.audiobook(
          for: manifest,
          bookIdentifier: book.identifier,
          decryptor: drmDecryptor,
          token: book.bearerToken
        ) else {
          Log.error(#file, "❌ AudiobookFactory failed to create audiobook")
          self.presentUnsupportedItemError()
          completion?()
          return
        }
        
        Log.info(#file, "✅ Audiobook created successfully")
        
        // Streaming resources are now handled automatically by LCPPlayer - no early population needed
        
        Log.info(#file, "✅ Launching audiobook player")
        
        self.launchAudiobook(book: book, audiobook: audiobook, drmDecryptor: drmDecryptor)
        completion?()
      }
    }
  }
  
  @MainActor private func launchAudiobook(book: TPPBook, audiobook: Audiobook, drmDecryptor: DRMDecryptor?) {
    Log.info(#file, "🎵 Launching audiobook player for: \(book.identifier)")
    Log.info(#file, "🎵 Audiobook has \(audiobook.tableOfContents.allTracks.count) tracks")
    
    var timeTracker: AudiobookTimeTracker?
    if let libraryId = AccountsManager.shared.currentAccount?.uuid, let timeTrackingURL = book.timeTrackingURL {
      timeTracker = AudiobookTimeTracker(libraryId: libraryId, bookId: book.identifier, timeTrackingUrl: timeTrackingURL)
    }
    
    let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""])
    
    audiobookManager = DefaultAudiobookManager(
      metadata: metadata,
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks, decryptor: drmDecryptor),
      playbackTrackerDelegate: timeTracker
    )
    
    guard let audiobookManager else {
      Log.error(#file, "❌ Failed to create audiobook manager")
      return
    }
    
    Log.info(#file, "✅ AudiobookManager created successfully")
    
    audiobookBookmarkBusinessLogic = AudiobookBookmarkBusinessLogic(book: book)
    audiobookManager.bookmarkDelegate = audiobookBookmarkBusinessLogic
    audiobookPlayer = AudiobookPlayer(audiobookManager: audiobookManager, coverImagePublisher: book.$coverImage.eraseToAnyPublisher())
    
    Log.info(#file, "✅ AudiobookPlayer created, presenting view controller")
    TPPRootTabBarController.shared().pushViewController(audiobookPlayer!, animated: true)
    
    Log.info(#file, "🎵 Syncing audiobook location and starting playback")
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
      // No saved location - start playing from the beginning
      startPlaybackFromBeginning()
      return
    }
    
    // Streaming resources are now handled automatically by LCPPlayer
    
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
          // Streaming resources are now handled automatically by LCPPlayer
          
          self.audiobookManager?.audiobook.player.play(at: position, completion: nil)
        }
      }
    }
  }
  
  /// Starts audiobook playback from the beginning (first track, position 0)
  private func startPlaybackFromBeginning() {
    guard let manager = audiobookManager,
          let firstTrack = manager.audiobook.tableOfContents.tracks.first else {
      Log.error(#file, "Cannot start playback: no audiobook manager or tracks")
      return
    }
    
    // Create position for start of first track
    let startPosition = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: manager.audiobook.tableOfContents.tracks)
    
    // Streaming resources are now handled automatically by LCPPlayer
    
    Log.info(#file, "Starting audiobook playbook from beginning")
    audiobookManager?.audiobook.player.play(at: startPosition, completion: nil)
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

// MARK: – BookButtonProvider
extension BookDetailViewModel: BookButtonProvider {
  var buttonTypes: [BookButtonType] {
    buttonState.buttonTypes(book: book)
  }
}

// MARK: - LCP Streaming Enhancement

private extension BookDetailViewModel {
  /// For LCP audiobooks, Readium 2.1.0 already provides proper streaming support
  /// No enhancement needed - just use the manifest as-is from Readium
  func enhanceManifestForLCPStreaming(manifest: PalaceAudiobookToolkit.Manifest, drmDecryptor: DRMDecryptor?) -> PalaceAudiobookToolkit.Manifest {
    Log.debug(#file, "🔍 enhanceManifestForLCPStreaming called with drmDecryptor: \(type(of: drmDecryptor))")
    
    // For LCP audiobooks, Readium already handles streaming correctly via DRMDecryptor.decrypt
    if drmDecryptor is LCPAudiobooks {
      Log.info(#file, "✅ LCP audiobook detected - using Readium 2.1.0 streaming (no enhancement needed)")
      Log.info(#file, "✅ Manifest has \(manifest.readingOrder?.count ?? 0) tracks, will use Readium streaming")
      return manifest // Use as-is - Readium handles streaming via decrypt() calls
    }
    
    Log.debug(#file, "Not an LCP audiobook, using original manifest")
    return manifest
  }
  
  /// Extract publication URL from LCPAudiobooks instance
  func getPublicationUrl(from lcpAudiobooks: LCPAudiobooks) -> URL? {
    // For now, we need to reconstruct the publication URL
    // Since we know this came from openAudiobookUnified, we can get it from the book's license
    
    guard let licenseUrl = getLCPLicenseURL(for: book),
          let license = TPPLCPLicense(url: licenseUrl),
          let publicationLink = license.firstLink(withRel: .publication),
          let href = publicationLink.href,
          let publicationUrl = URL(string: href) else {
      Log.error(#file, "Failed to extract publication URL from license for streaming enhancement")
      return nil
    }
    
    Log.debug(#file, "📥 Extracted publication URL for streaming: \(publicationUrl.absoluteString)")
    return publicationUrl
  }
  

  

}

extension BookDetailViewModel: HalfSheetProvider {}
