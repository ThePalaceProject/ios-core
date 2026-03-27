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

    /// Error alert to present via SwiftUI `.alert`, ensuring it shows
    /// on top of the half sheet instead of being swallowed by UIKit.
    @Published var downloadErrorAlert: AlertModel?

    @Published var relatedBooksByLane: [String: BookLane] = [:]
    @Published var isLoadingRelatedBooks = false

    /// Tracks the book identifier we last fetched related books for.
    /// Used to preserve related books when view reappears after modal dismissal.
    private var relatedBooksBookIdentifier: String?
    @Published var isLoadingDescription = false
    @Published var selectedBookURL: URL?
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
    private(set) lazy var actionHandler: BookActionHandler = {
        let handler = BookActionHandler(downloadCenter: downloadCenter)
        handler.attach(to: self)
        return handler
    }()
    private var cancellables = Set<AnyCancellable>()

    // Note: audiobook management moved to BookService
    private var audiobookPlayer: AudiobookPlayer?
    private var audiobookBookmarkBusinessLogic: AudiobookBookmarkBusinessLogic?
    private var timer: DispatchSourceTimer?
    private var previousPlayheadOffset: TimeInterval = 0
    private var didPrefetchLCPStreaming = false
    private var isReconcilingLocation: Bool = false
    private var recentMoveAt: Date?
    private var isSyncingLocation: Bool = false
    private let bookIdentifier: String
    private var localBookStateOverride: TPPBookState?

    // MARK: - Computed Button State

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
            let reported = downloadCenter.downloadProgress(for: book.identifier)
            self.downloadProgress = max(self.downloadProgress, reported)
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
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let updatedBook = registry.book(forIdentifier: book.identifier) ?? book
                let registryState = registry.state(for: book.identifier)

                self.book = updatedBook

                if let override = self.localBookStateOverride, override == .returning, registryState != .unregistered {
                    return
                }
                self.bookState = registryState

                switch registryState {
                case .unregistered:
                    self.isManagingHold = false
                    self.showHalfSheet = false
                    self.processingButtons.remove(.returning)
                    self.processingButtons.remove(.cancelHold)
                    self.processingButtons.remove(.return)
                    self.processingButtons.remove(.remove)

                case .downloading:
                    self.processingButtons.remove(.download)
                    self.processingButtons.remove(.get)
                    self.processingButtons.remove(.retry)

                case .downloadFailed:
                    self.processingButtons.remove(.download)
                    self.processingButtons.remove(.get)
                    self.processingButtons.remove(.retry)

                case .downloadSuccessful, .used:
                    self.processingButtons.remove(.download)
                    self.processingButtons.remove(.get)
                    self.processingButtons.remove(.retry)

                case .holding:
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

        downloadCenter.downloadProgressPublisher
            .filter { $0.0 == self.book.identifier }
            .map { [weak self] update -> Double in
                max(self?.downloadProgress ?? 0.0, update.1)
            }
            .assign(to: &$downloadProgress)

        downloadCenter.downloadErrorPublisher
            .filter { [weak self] in $0.bookId == self?.book.identifier }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorInfo in
                if let retryAction = errorInfo.retryAction {
                    self?.downloadErrorAlert = .retryable(
                        title: errorInfo.title,
                        message: errorInfo.message,
                        retryAction: retryAction
                    )
                } else {
                    self?.downloadErrorAlert = AlertModel(title: errorInfo.title, message: errorInfo.message)
                }
            }
            .store(in: &cancellables)
    }

    private func computeButtonState(book: TPPBook, state: TPPBookState, isManagingHold: Bool) -> BookButtonState {
        let availability = book.defaultAcquisition?.availability
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
        Publishers.CombineLatest4($book, $bookState, $isManagingHold, $isProcessing)
            .map { [weak self] book, state, isManaging, _ in
                self?.computeButtonState(book: book, state: state, isManagingHold: isManaging) ?? .unsupported
            }
            .removeDuplicates()
            .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
            .assign(to: &self.$stableButtonState)
    }

    @objc func handleBookRegistryChange(_ notification: Notification) {
        let updatedBook = registry.book(forIdentifier: book.identifier) ?? book
        DispatchQueue.main.async {
            self.book = updatedBook
        }
    }

    func selectRelatedBook(_ newBook: TPPBook) {
        guard newBook.identifier != book.identifier else { return }
        relatedBooksByLane = [:]
        relatedBooksBookIdentifier = nil
        book = newBook
        bookState = registry.state(for: newBook.identifier)
        fetchRelatedBooks()
    }

    // MARK: - Notifications

    @objc func handleDownloadStateDidChange(_ notification: Notification) {
        Task { @MainActor in
            let reported = downloadCenter.downloadProgress(for: book.identifier)
            self.downloadProgress = max(self.downloadProgress, reported)
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

        let currentBookId = book.identifier

        let isSameBook = relatedBooksBookIdentifier == currentBookId ||
            (relatedBooksBookIdentifier == nil && !relatedBooksByLane.isEmpty)

        if !isSameBook {
            relatedBooksByLane = [:]
        }
        relatedBooksBookIdentifier = currentBookId

        isLoadingRelatedBooks = true

        TPPOPDSFeed.withURL(url, shouldResetCache: false, useTokenIfAvailable: TPPUserAccount.sharedAccount().hasAdobeToken()) { [weak self] feed, _ in
            guard let self else { return }

            DispatchQueue.main.async {
                guard self.book.identifier == currentBookId else {
                    self.isLoadingRelatedBooks = false
                    return
                }

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
            if lanesMap.isEmpty && !self.relatedBooksByLane.isEmpty {
                self.isLoadingRelatedBooks = false
                return
            }
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

    // MARK: - Button Actions (delegated to BookActionHandler)

    func handleAction(for button: BookButtonType) {
        actionHandler.handleAction(for: button)
    }

    func removeProcessingButton(_ button: BookButtonType) {
        self.processingButtons.remove(button)
    }

    func isProcessing(for button: BookButtonType) -> Bool {
        processingButtons.contains(button)
    }

    // MARK: - Forwarding methods for backward compatibility

    func didSelectDownload(for book: TPPBook) {
        actionHandler.didSelectDownload(for: book)
    }

    func didSelectReserve(for book: TPPBook, completion: (() -> Void)? = nil) {
        actionHandler.didSelectReserve(for: book, completion: completion)
    }

    func didSelectCancel() {
        actionHandler.didSelectCancel()
    }

    func didSelectReturn(for book: TPPBook, completion: (() -> Void)?) {
        actionHandler.didSelectReturn(for: book, completion: completion)
    }

    @MainActor
    func didSelectRead(for book: TPPBook, completion: (() -> Void)?) {
        actionHandler.didSelectRead(for: book, completion: completion)
    }

    @MainActor
    func openBook(_ book: TPPBook, completion: (() -> Void)?) {
        actionHandler.openBook(book, completion: completion)
    }

    func openAudiobook(_ book: TPPBook, completion: (() -> Void)? = nil) {
        BookService.open(book, onFinish: completion)
    }

    func didSelectPlaySample(for book: TPPBook, completion: (() -> Void)?) {
        actionHandler.didSelectPlaySample(for: book, completion: completion)
    }

    // MARK: - LCP

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
}

// MARK: - Timer & Audiobook Polling

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
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Audiobook Location Sync (delegates to BookAvailabilityFormatter)

extension BookDetailViewModel {
    func chooseLocalLocation(localPosition: TrackPosition?, remotePosition: TrackPosition?, serverUpdateDelay: TimeInterval, operation: @escaping (TrackPosition) -> Void) {
        BookAvailabilityFormatter.chooseLocalLocation(
            localPosition: localPosition,
            remotePosition: remotePosition,
            serverUpdateDelay: serverUpdateDelay,
            operation: operation
        )
    }

    func requestSyncWithCompletion(completion: @escaping (Bool) -> Void) {
        BookAvailabilityFormatter.requestSyncWithCompletion(completion: completion)
    }

    static func presentEndOfBookAlert(for book: TPPBook) {
        BookAvailabilityFormatter.presentEndOfBookAlert(for: book)
    }

    private func presentEndOfBookAlert() {
        BookDetailViewModel.presentEndOfBookAlert(for: book)
    }
}

// MARK: - BookButtonProvider
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
