import Combine
import SwiftUI
import PalaceAudiobookToolkit
import PalaceLogging
import PalaceCatalog

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

    /// True while the background `.lcpa` content re-download for this book is
    /// running. Drives the half-sheet progress cue for the case where the book
    /// is `.downloadSuccessful` but its content package is absent, which the
    /// `bookState == .downloading` cue cannot cover.
    @Published var isDownloadingLCPContent: Bool = false

    /// Error alert to present via SwiftUI `.alert`, ensuring it shows
    /// on top of the half sheet instead of being swallowed by UIKit.
    @Published var downloadErrorAlert: AlertModel?

    /// Confirmation alert shown before a destructive action (e.g. cancel hold)
    /// that would otherwise execute immediately without a second confirmation step.
    @Published var confirmationAlert: AlertModel?

    /// SQ-008: Alert surfaced by the HalfSheetProvider protocol so that
    /// cancel-hold and return confirmations render ON the half-sheet
    /// (not behind it on the parent BookCell).
    @Published var showAlert: AlertModel?

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

    /// `true` while BorrowOperation has the registry's processing flag set
    /// for this book — i.e. a borrow request is in flight. Distinct from
    /// `downloadProgress` (which is 0 for the entire borrow phase, before
    /// the download itself starts) and from `processingButtons` (which
    /// tracks user-initiated UI spinners on individual buttons).
    ///
    /// Surfacing this flag fixes the "borrow stuck with Cancel-only UI" bug
    /// on slow distributors (Overdrive in particular): before this, the
    /// half-sheet rendered a 0%-linear progress bar and an inert Cancel
    /// button with no indeterminate spinner, so the user had no signal that
    /// anything was happening. BorrowOperation's setProcessing(true:false)
    /// pair is the canonical truth here; we mirror it via the existing
    /// `.TPPBookProcessingDidChange` notification so unit tests can flip it
    /// without standing up the full download stack.
    @Published private(set) var isBorrowProcessing: Bool = false

    var isShowingSample = false
    var isProcessingSample = false

    // MARK: - Dependencies

    let registry: TPPBookRegistryProvider
    let downloadCenter: MyBooksDownloadCenter
    private let accountsManager: AccountsManager
    private let settings: TPPSettings
    private let opdsFeedService: OPDSFeedService
    private let samplePreviewManager: SamplePreviewManager
    private let readerService: ReaderService
    private let metadataHydrator: BookMetadataHydrator
    private var cancellables = Set<AnyCancellable>()

    typealias BookMetadataHydrator = (URL) async throws -> TPPBook?

    // Note: audiobook management moved to BookService
    // private var audiobookViewController: UIViewController? // No longer used
    // private var audiobookManager: DefaultAudiobookManager? // No longer used
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

    // MARK: – Computed Button State

    var buttonState: BookButtonState { stableButtonState }

    // MARK: - Initializer

    @objc convenience init(book: TPPBook) {
        self.init(book: book, appContainer: .production())
    }

    /// Standard composition path — wraps the AppContainer service graph.
    convenience init(book: TPPBook, appContainer: AppContainer) {
        self.init(
            book: book,
            registry: appContainer.bookRegistry,
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: appContainer.settings,
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService
        )
    }

    /// Initializer with dependency injection for testing
    init(
        book: TPPBook,
        registry: TPPBookRegistryProvider,
        downloadCenter: MyBooksDownloadCenter,
        accountsManager: AccountsManager,
        settings: TPPSettings,
        opdsFeedService: OPDSFeedService,
        samplePreviewManager: SamplePreviewManager,
        readerService: ReaderService,
        metadataHydrator: BookMetadataHydrator? = nil
    ) {
        self.book = book
        self.registry = registry
        self.downloadCenter = downloadCenter
        self.accountsManager = accountsManager
        self.settings = settings
        self.opdsFeedService = opdsFeedService
        self.samplePreviewManager = samplePreviewManager
        self.readerService = readerService
        // Default hydrator captures the injected services instead of reading
        // .shared singletons. Tests pass a custom hydrator to short-circuit.
        self.metadataHydrator = metadataHydrator ?? { url in
            let feed = try await opdsFeedService.fetchFeed(
                from: url,
                useToken: accountsManager.currentUserAccount.hasAdobeToken()
            )
            guard let entries = feed.entries as? [TPPOPDSEntry],
                  let entry = entries.first else { return nil }
            return TPPBook(entry: entry)
        }
        self.bookState = registry.state(for: book.identifier)
        self.bookIdentifier = book.identifier
        self.stableButtonState = self.computeButtonState(book: book, state: self.bookState, isManagingHold: self.isManagingHold)
        // Seed isBorrowProcessing from the registry's processing flag so a
        // borrow that's already in flight when the detail view opens (e.g.
        // user kicked it off from a swimlane, then navigated into details
        // before the network round-trip returned) shows the spinner from
        // first frame instead of looking idle until the next emission.
        self.isBorrowProcessing = registry.processing(forIdentifier: book.identifier)

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
        if let licenseUrl = Self.lcpLicenseURL(forBookIdentifier: bookIdentifier, downloadCenter: downloadCenter) {
            var lcpAudiobooks: LCPAudiobooks?
            if let localURL = downloadCenter.fileUrl(for: bookIdentifier),
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
            .sink { [weak self] _ in
                guard let self else { return }
                let updatedBook = registry.book(forIdentifier: book.identifier) ?? book
                let registryState = registry.state(for: book.identifier)

                // Always update book from registry - it has authoritative data including loan duration
                // after borrowing completes. The old optimization (only update if identifier/title changed)
                // was too aggressive and missed availability data changes needed for the HalfSheet.
                self.book = updatedBook

                // Run the registry-state transition through BorrowReducer so the
                // legacy switch is testable in isolation (see BorrowReducerTests).
                var snapshot = self.snapshotBorrowState()
                _ = BorrowReducer.reduce(&snapshot, .registryStateChanged(registryState))
                self.applyBorrowState(snapshot)
            }
            .store(in: &cancellables)
    }

    /// Reads the relevant slice of VM @Published state into a `BorrowState`
    /// value type so the reducer can mutate it in isolation. Cosmetic VM
    /// fields (related books, alerts, sample state, etc.) live outside this
    /// snapshot — the reducer only owns the borrow lifecycle.
    private func snapshotBorrowState() -> BorrowState {
        BorrowState(
            bookState: bookState,
            localBookStateOverride: localBookStateOverride,
            downloadProgress: downloadProgress,
            processingButtons: processingButtons,
            isManagingHold: isManagingHold,
            showHalfSheet: showHalfSheet
        )
    }

    /// Mirrors the post-reduce state back onto VM @Published properties.
    /// Guards each write with an inequality check so we avoid an unnecessary
    /// objectWillChange spam — Combine subscribers (e.g. button-state
    /// throttling) only fire when something actually changed.
    private func applyBorrowState(_ state: BorrowState) {
        if bookState != state.bookState {
            bookState = state.bookState
        }
        if localBookStateOverride != state.localBookStateOverride {
            localBookStateOverride = state.localBookStateOverride
        }
        if downloadProgress != state.downloadProgress {
            downloadProgress = state.downloadProgress
        }
        if processingButtons != state.processingButtons {
            processingButtons = state.processingButtons
        }
        if isManagingHold != state.isManagingHold {
            isManagingHold = state.isManagingHold
        }
        if showHalfSheet != state.showHalfSheet {
            showHalfSheet = state.showHalfSheet
        }
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBookRegistryChange(_:)),
            name: .TPPBookRegistryDidChange,
            object: nil
        )

        // BorrowOperation posts .TPPBookProcessingDidChange via the registry
        // when it starts a borrow request and again when it finishes. Mirror
        // it onto an @Published flag the half-sheet can observe, filtered to
        // this VM's book identifier so unrelated borrows don't spin our UI.
        NotificationCenter.default.publisher(for: .TPPBookProcessingDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self else { return }
                guard let info = note.userInfo as? [String: Any],
                      let identifier = info[TPPNotificationKeys.bookProcessingBookIDKey] as? String,
                      identifier == self.bookIdentifier,
                      let value = info[TPPNotificationKeys.bookProcessingValueKey] as? Bool else { return }
                if self.isBorrowProcessing != value {
                    self.isBorrowProcessing = value
                }
            }
            .store(in: &cancellables)

        // Avoid general download center change notifications; we already subscribe to fine-grained progress and registry state publishers

        downloadCenter.downloadProgressPublisher
            .filter { $0.0 == self.book.identifier }
            .map { [weak self] update -> Double in
                // Clamp to max-seen-so-far to prevent progress bar from sliding backwards
                max(self?.downloadProgress ?? 0.0, update.1)
            }
            .assign(to: &$downloadProgress)

        // LCP audiobook content re-download: the book is already
        // `.downloadSuccessful` from an earlier session and only its `.lcpa`
        // went missing, so the download-state-driven progress bar does not
        // apply. This flag lets the half-sheet show the bar for that case.
        //
        // A dedicated signal rather than an inference from `downloadProgress`:
        // that value is clamped monotonically upward above, so for a book whose
        // earlier download already reached 1.0 every fresh sample would clamp
        // back to 1.0 and a new transfer would be undetectable.
        downloadCenter.lcpContentDownloadPublisher
            .filter { [weak self] in $0.0 == self?.book.identifier }
            .receive(on: RunLoop.main)
            .sink { [weak self] update in
                guard let self else { return }
                let isActive = update.1
                // Zero the progress on the rising edge. `downloadProgress` is
                // clamped monotonically upward above, so a book whose earlier
                // download already reached 1.0 would render a full bar for the
                // entire new transfer. Resetting here re-bases the clamp for
                // this download.
                if isActive && !self.isDownloadingLCPContent {
                    self.downloadProgress = 0.0
                }
                self.isDownloadingLCPContent = isActive
            }
            .store(in: &cancellables)

        // Subscribe to download errors so we can present them via SwiftUI .alert
        // instead of UIKit (which can fail when a SwiftUI sheet is topmost).
        // Filter by error kind so borrow errors only show when the user initiated
        // a borrow (Get), and download errors only show for downloads/retries.
        downloadCenter.downloadErrorPublisher
            .filter { [weak self] in $0.bookId == self?.book.identifier }
            .filter { [weak self] errorInfo in
                guard let self else { return true }
                switch errorInfo.kind {
                case .borrow:
                    return self.processingButtons.contains(.get) || self.bookState == .unregistered
                case .download:
                    return self.processingButtons.contains(.download) || self.processingButtons.contains(.retry)
                        || self.bookState == .downloading || self.bookState == .downloadFailed || self.bookState == .downloadNeeded
                case .general:
                    return true
                }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorInfo in
                guard let self else { return }

                if let retryAction = errorInfo.retryAction {
                    self.downloadErrorAlert = .retryable(
                        title: errorInfo.title,
                        message: errorInfo.message,
                        retryAction: retryAction
                    )
                } else {
                    self.downloadErrorAlert = AlertModel(title: errorInfo.title, message: errorInfo.message)
                }

                // startDownloadAfterAuth sets bookState =
                // .downloading and shows a Cancel button in the half-sheet
                // before the download task even runs. When the download is
                // refused (Wi-Fi-only on cellular, auth issue, etc.), nothing
                // reverts that local UI state, so the sheet gets stuck on
                // "Cancel" forever and the user thinks the download is in
                // flight. Re-sync bookState and the processing buttons to the
                // registry's truth so the UI reflects the failure.
                self.bookState = self.registry.state(for: self.book.identifier)
                self.processingButtons.remove(.download)
                self.processingButtons.remove(.get)
                self.processingButtons.remove(.retry)
                self.processingButtons.remove(.reserve)
                self.downloadProgress = 0
            }
            .store(in: &cancellables)
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

        // Clear related books data since we're navigating to a different book
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

    // MARK: - Metadata Hydration

    /// Some OPDS servers serve lightweight `<entry>` blocks inside grouped-lane
    /// feeds — they omit `<dcterms:issued>`, `<bibframe:publisher>`,
    /// `<distribution>`, and `<category>`. When the user lands on the detail
    /// view from a swimlane, the INFORMATION section would render empty rows.
    /// Re-fetching the single-entry feed at `alternateURL` returns the full
    /// metadata; we merge the missing fields in without disturbing navigational
    /// state (acquisitions, related/revoke/report URLs) that the lane entry
    /// does populate.
    func hydrateMetadataIfNeeded() async {
        guard Self.needsMetadataHydration(book) else { return }
        guard let url = book.alternateURL else { return }

        let targetIdentifier = book.identifier
        do {
            guard let fresh = try await metadataHydrator(url) else { return }
            guard book.identifier == targetIdentifier else { return }
            guard Self.needsMetadataHydration(book) else { return }

            let merged = Self.mergeHydratedMetadata(into: book, fresh: fresh)
            book = merged
            _ = registry.updatedBookMetadata(merged)
        } catch {
            Log.warn(#file, "Failed to hydrate book metadata: \(error.localizedDescription)")
        }
    }

    private static func needsMetadataHydration(_ book: TPPBook) -> Bool {
        book.published == nil
            && (book.publisher?.isEmpty ?? true)
            && (book.distributor?.isEmpty ?? true)
            && (book.categoryStrings?.isEmpty ?? true)
            && (book.audience?.isEmpty ?? true)
            && (book.language?.isEmpty ?? true)
    }

    private static func mergeHydratedMetadata(into current: TPPBook, fresh: TPPBook) -> TPPBook {
        TPPBook(
            acquisitions: current.acquisitions,
            authors: current.bookAuthors,
            categoryStrings: (current.categoryStrings?.isEmpty ?? true) ? fresh.categoryStrings : current.categoryStrings,
            distributor: (current.distributor?.isEmpty ?? true) ? fresh.distributor : current.distributor,
            identifier: current.identifier,
            imageURL: current.imageURL ?? fresh.imageURL,
            imageThumbnailURL: current.imageThumbnailURL ?? fresh.imageThumbnailURL,
            published: current.published ?? fresh.published,
            publisher: (current.publisher?.isEmpty ?? true) ? fresh.publisher : current.publisher,
            subtitle: current.subtitle ?? fresh.subtitle,
            summary: (current.summary?.isEmpty ?? true) ? fresh.summary : current.summary,
            title: current.title,
            updated: current.updated,
            annotationsURL: current.annotationsURL,
            analyticsURL: current.analyticsURL,
            alternateURL: current.alternateURL,
            relatedWorksURL: current.relatedWorksURL,
            previewLink: current.previewLink ?? fresh.previewLink,
            seriesURL: current.seriesURL ?? fresh.seriesURL,
            seriesName: (current.seriesName?.isEmpty ?? true) ? fresh.seriesName : current.seriesName,
            revokeURL: current.revokeURL,
            reportURL: current.reportURL,
            timeTrackingURL: current.timeTrackingURL,
            contributors: current.contributors,
            bookDuration: (current.bookDuration?.isEmpty ?? true) ? fresh.bookDuration : current.bookDuration,
            audience: (current.audience?.isEmpty ?? true) ? fresh.audience : current.audience,
            language: (current.language?.isEmpty ?? true) ? fresh.language : current.language,
            imageCache: current.imageCache
        )
    }

    // MARK: - Related Books

    func fetchRelatedBooks() {
        guard let url = book.relatedWorksURL else { return }

        let currentBookId = book.identifier

        // Only clear existing related books if we're fetching for a different book.
        // This prevents the "Other Books By This Author" section from disappearing
        // when the view reappears (e.g., after closing a sample preview).
        // If relatedBooksBookIdentifier is nil but we have data, assume it belongs to the current book.
        let isSameBook = relatedBooksBookIdentifier == currentBookId ||
            (relatedBooksBookIdentifier == nil && !relatedBooksByLane.isEmpty)

        if !isSameBook {
            relatedBooksByLane = [:]
        }
        relatedBooksBookIdentifier = currentBookId

        isLoadingRelatedBooks = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let feed = try await opdsFeedService.fetchFeed(from: url, useToken: accountsManager.currentUserAccount.hasAdobeToken())

                await MainActor.run {
                    guard self.book.identifier == currentBookId else {
                        self.isLoadingRelatedBooks = false
                        return
                    }

                    if feed.type == .acquisitionGrouped {
                        var groupTitleToBooks: [String: [TPPBook]] = [:]
                        var groupTitleToMoreURL: [String: URL?] = [:]
                        if let entries = feed.entries as? [TPPOPDSEntry] {
                            for entry in entries {
                                guard let group = entry.groupAttributes else { continue }
                                let groupTitle = group.title ?? ""
                                if let b = CatalogViewModel.makeBook(from: entry, bookRegistry: registry) {
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
            } catch {
                Log.warn(#file, "Failed to fetch related books: \(error.localizedDescription)")
                await MainActor.run { self.isLoadingRelatedBooks = false }
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
            // Don't replace existing related books with empty data.
            // This can happen if the network request succeeds but parsing fails.
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
            // PP-4161 Wave 4 (Path X): streaming-HTML titles funnel through
            // the same didSelectDownload path as every other content type.
            // DownloadStartDispatcher.processUnregisteredState already sets
            // the registry to .downloadNeeded via the open-access branch,
            // and processDownloadWithCredentials early-returns for
            // streamingHTML (no asset to download). The button set then
            // maps to [.readStreaming, .return] on next render, so the
            // user taps Read on a second tap.
            didSelectDownload(for: book)
        // Don't remove processing here - will be removed when state changes to .downloading or .downloadFailed

        case .read, .listen:
            // PP-4633: dismiss the half-sheet so it does not linger over the
            // reader/player. On iPhone the .medium detent is covered by the
            // full-screen presentation; on iPad it renders as a floating
            // form-sheet that otherwise stays on screen.
            //
            // The dismiss MUST happen in the open completion (after the
            // reader/player is presented), NOT on tap: on iPad, dismissing the
            // form-sheet while the player is being presented races the two
            // modal transitions, so the player fails to present and the screen
            // freezes. Presenting first, then dismissing the sheet underneath,
            // avoids the race. Mirrors the .reserve / .return cases.
            didSelectRead(for: book) {
                self.removeProcessingButton(button)
                self.showHalfSheet = false
            }

        case .readStreaming:
            // PP-4161: streaming-HTML titles don't go through ensureAuthAndExecute
            // / openBook; the asset is online-only and presented directly via
            // the NavigationCoordinator streamingHTML route. processingButtons
            // is cleared after the route push completes.
            // PP-4633: dismiss the half-sheet in the completion (after the
            // reader is presented), same ordering as .read/.listen.
            didSelectReadStreaming(for: book) {
                self.removeProcessingButton(button)
                self.showHalfSheet = false
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
        }
    }

    func removeProcessingButton(_ button: BookButtonType) {
        self.processingButtons.remove(button)
    }

    func isProcessing(for button: BookButtonType) -> Bool {
        processingButtons.contains(button)
    }

    // MARK: - Authentication Helper

    /// Ensures authentication document is loaded and handles sign-in if needed.
    private func ensureAuthAndExecute(_ action: @escaping () -> Void) {
        let businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: accountsManager.currentAccount?.uuid ?? "",
            libraryAccountsProvider: accountsManager,
            urlSettingsProvider: settings,
            bookRegistry: (registry as? TPPBookRegistrySyncing) ?? { preconditionFailure("registry must conform to TPPBookRegistrySyncing") }(),
            bookDownloadsCenter: downloadCenter,
            userAccountProvider: TPPUserAccount.self,
            uiDelegate: nil,
            drmAuthorizer: nil
        )

        businessLogic.ensureAuthenticationDocumentIsLoaded { [weak self] (_: Bool) in
            DispatchQueue.main.async {
                guard let self = self else { return }

                let account = self.accountsManager.currentUserAccount
                let needsSignIn = account.needsAuth && !account.hasCredentials()
                // .credentialsStale means we still hold credentials but a 401
                // has marked the session expired. Reading the cached book
                // proceeds straight to a hung reader (no fresh fulfillment,
                // no fresh DRM grant) without an intervening sign-in. Force
                // re-auth here so the user has a path to recover without
                // reinstalling. HelpSpot 17716 (Cornell SAML).
                let needsReauth = account.authState == .credentialsStale
                if needsSignIn || needsReauth {
                    Log.info(#file, "[SAML-REAUTH] ensureAuthAndExecute presenting modal: needsSignIn=\(needsSignIn) needsReauth=\(needsReauth)")
                    let halfSheetWasShowing = self.showHalfSheet
                    self.showHalfSheet = false
                    // swarm_d8f11437 Module A wave 4 — migrated to
                    // AppContainer-injected sheet presenter. self.accountsManager
                    // is the same `_cached` singleton the presenter resolves
                    // internally, so the behavior is preserved.
                    AppContainer.production().signInModalSheetPresenter
                        .presentSignInModalForCurrentAccount { [weak self] in
                            guard let self else { return }
                            let post = self.accountsManager.currentUserAccount
                            // Proceed only if the user actually re-authenticated
                            // — they have credentials AND state is loggedIn.
                            // Cancelling the modal leaves authState unchanged
                            // (still .credentialsStale) and we should NOT call
                            // the action; otherwise we'd hand the reader a stale
                            // book and reproduce the original hang.
                            guard post.hasCredentials() && post.authState == .loggedIn else {
                                Log.info(#file, "[SAML-REAUTH] Sign-in cancelled or incomplete (hasCredentials=\(post.hasCredentials()) authState=\(post.authState)) — not proceeding with action")
                                // Clear ALL processing state. A bailed-out modal can
                                // leave .read/.listen/.reserve/etc. stuck in the set,
                                // and `handleAction` ignores any tap whose button is
                                // already processing — i.e. the next Read tap is
                                // silently dropped until the view is recreated.
                                self.processingButtons.removeAll()
                                // Restore the half-sheet so the patron can retry. We
                                // only re-show it if the caller had it open before
                                // the modal stole the screen (e.g. download in
                                // flight); pure book-detail actions like Read don't
                                // use the half-sheet and shouldn't summon it now.
                                if halfSheetWasShowing {
                                    self.showHalfSheet = true
                                }
                                return
                            }
                            // Restore the half-sheet on the success path too — it
                            // was only dismissed to make room for the SAML modal.
                            if halfSheetWasShowing {
                                self.showHalfSheet = true
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
                let user = self.accountsManager.currentUserAccount

                if user.hasCredentials() {
                    if user.hasAuthToken() {
                        self.openBook(book, completion: completion)
                        return
                    } else if AdobeCertificate.isDRMAvailable &&
                                !AdobeDRMService.shared.isUserAuthorized(user.userID, deviceID: user.deviceID) {
                        // On-demand DRM activation instead of showing sign-in modal
                        Task {
                            do {
                                try await AdobeDRMService.shared.ensureDeviceActivated()
                                await MainActor.run { self.openBook(book, completion: completion) }
                            } catch {
                                Log.error(#file, "Adobe DRM activation failed for open: \(error.localizedDescription)")
                                await MainActor.run { completion?() }
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
            presentEPUB(resolvedBook) { [weak self] in
                DispatchQueue.main.async {
                    self?.processingButtons.removeAll()
                    completion?()
                }
            }
        case .pdf:
            Log.debug(#file, "  → Opening as PDF")
            presentPDF(resolvedBook) { [weak self] in
                DispatchQueue.main.async {
                    self?.processingButtons.removeAll()
                    completion?()
                }
            }
        case .audiobook:
            Log.debug(#file, "  → Opening as AUDIOBOOK")
            openAudiobook(resolvedBook) { [weak self] in
                DispatchQueue.main.async {
                    self?.processingButtons.removeAll()
                    completion?()
                }
            }
        case .streamingHTML:
            // PP-4161: streaming-media titles use the in-app WKWebView reader
            // presented via NavigationCoordinator. Note: handleAction(.readStreaming)
            // is the canonical entry point; this case handles the rare path
            // where some other call site funnels a streamingHTML book through
            // openBook(_:completion:) (e.g. a coordinator-level resume).
            Log.debug(#file, "  → Opening as STREAMING-HTML")
            presentStreamingReader(resolvedBook)
            processingButtons.removeAll()
            completion?()
        default:
            Log.error(#file, "  ❌ UNSUPPORTED CONTENT TYPE - showing error to user")
            processingButtons.removeAll()
            presentUnsupportedItemError()
        }
    }

    @MainActor private func presentEPUB(_ book: TPPBook, completion: (() -> Void)? = nil) {
        BookService.open(book, onFinish: completion)
    }

    @MainActor private func presentPDF(_ book: TPPBook, completion: (() -> Void)? = nil) {
        BookService.open(book, onFinish: completion)
    }

    // MARK: - Audiobook Opening

    func openAudiobook(_ book: TPPBook, completion: (() -> Void)? = nil) {
        BookService.open(book, onFinish: completion)
    }

    // MARK: - Streaming HTML Reader (PP-4161)

    /// Presents the in-app WKWebView reader for streaming-media (text/html)
    /// titles. Distinct from `didSelectRead` because there's no auth document
    /// dependency (no DRM grant), no openBook dispatch (no LCP / Readium /
    /// audiobook session), and no `BookService.open` reentrancy guard — we
    /// route straight to `NavigationCoordinator.push(.streamingHTML(...))`.
    @MainActor
    func didSelectReadStreaming(for book: TPPBook, completion: (() -> Void)? = nil) {
        TPPCirculationAnalytics.postEvent("open_book", withBook: book)
        presentStreamingReader(book)
        completion?()
    }

    /// Pushes the streamingHTML route on the navigation coordinator after
    /// storing the book payload so the destination resolver can look it up.
    @MainActor
    private func presentStreamingReader(_ book: TPPBook) {
        guard let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator else {
            Log.warn(#file, "No NavigationCoordinator available — cannot present streaming reader for \(book.identifier)")
            return
        }
        coordinator.store(book: book)
        coordinator.push(.streamingHTML(BookRoute(id: book.identifier)))
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
    nonisolated static func lcpLicenseURL(forBookIdentifier identifier: String, downloadCenter: MyBooksDownloadCenter) -> URL? {
        guard let bookFileURL = downloadCenter.fileUrl(for: identifier) else {
            return nil
        }
        let licenseURL = bookFileURL.deletingPathExtension().appendingPathExtension("lcpl")
        return FileManager.default.fileExists(atPath: licenseURL.path) ? licenseURL : nil
    }
    #endif

    #if LCP
    private func prefetchLCPStreamingIfPossible() {
        guard !didPrefetchLCPStreaming, LCPAudiobooks.canOpenBook(book), let licenseUrl = Self.lcpLicenseURL(forBookIdentifier: bookIdentifier, downloadCenter: downloadCenter) else { return }
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
                samplePreviewManager.close()
                presentWebView(book.sampleAcquisition?.hrefURL)
                isProcessingSample = false
                completion?()
            } else {

                samplePreviewManager.toggle(for: book)
                isProcessingSample = false
                completion?()
            }
        } else {
            samplePreviewManager.close()
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
                            self.readerService.openSample(book, url: sampleURL)
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
        guard let top = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() else { return }
        let controller = PreviewControllerFactory.makePreviewController(
            for: url,
            title: accountsManager.currentAccount?.name ?? ""
        )
        top.present(controller, animated: true)
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

    static func presentEndOfBookAlert(for book: TPPBook, downloadCenter: MyBooksDownloadCenter) {
        let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
            forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
            allowedRelations: TPPOPDSAcquisitionRelationSetBorrow | TPPOPDSAcquisitionRelationSetGeneric,
            acquisitions: book.acquisitions
        )

        if paths.count > 0 {
            let alert = TPPReturnPromptHelper.audiobookPrompt { returnWasChosen in
                if returnWasChosen {
                    AppContainer.production().navigationCoordinatorHub.coordinator?.pop()
                    downloadCenter.returnBook(withIdentifier: book.identifier)
                }
                TPPAppStoreReviewPrompt.presentIfAvailable()
            }
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
        } else {
            TPPAppStoreReviewPrompt.presentIfAvailable()
        }
    }

    private func presentEndOfBookAlert() {
        BookDetailViewModel.presentEndOfBookAlert(for: book, downloadCenter: downloadCenter)
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
