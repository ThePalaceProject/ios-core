//
//  BookCellModel.swift
//  Palace
//
//  Created by Maurice Carrier on 2/2/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import SwiftUI
import SafariServices
import PalaceAudiobookToolkit
import PalaceLogging
import PalaceNetwork

enum BookCellState {
    case normal(BookButtonState)
    case downloading(BookButtonState)
    case downloadFailed(BookButtonState)

    var buttonState: BookButtonState {
        switch self {
        case .normal(let state),
             .downloading(let state),
             .downloadFailed(let state):
            return state
        }
    }
}

extension BookCellState {
    init(_ bookButtonState: BookButtonState) {
        // Exhaustive (no `default:`) — F-011 class-of-bug guard. Compiler
        // flags this site if BookButtonState gains a case, so a download-
        // adjacent state can't silently classify as `.normal`.
        switch bookButtonState {
        case .downloadInProgress:
            self = .downloading(bookButtonState)
        case .downloadFailed:
            self = .downloadFailed(bookButtonState)
        case .canBorrow, .canHold, .holding, .holdingFrontOfQueue,
             .downloadNeeded, .downloadSuccessful, .used, .returning,
             .managingHold, .unsupported:
            self = .normal(bookButtonState)
        }
    }
}

@MainActor
class BookCellModel: ObservableObject {
    typealias DisplayStrings = Strings.BookCell

    @Published var image = UIImage()
    @Published var showAlert: AlertModel?
    @Published var downloadErrorAlert: AlertModel?
    @Published var isLoading: Bool = false {
        didSet {
            statePublisher.send(isLoading)
        }
    }

    // Debounce guard for the Read/Listen button. Rapid taps used to stack two
    // reader presentations (PP-4116) because isLoading flips back to false
    // synchronously after the presentation trigger.
    @Published private(set) var isPresentingReader: Bool = false
    private static let readerPresentationLockWindow: TimeInterval = 0.5

    @Published private var currentBookIdentifier: String?

    private var cancellables = Set<AnyCancellable>()
    let imageCache: ImageCacheType
    let bookRegistry: TPPBookRegistryProvider
    let downloadCenter: MyBooksDownloadCenter
    private let accountsManager: AccountsManager
    private let samplePreviewManager: SamplePreviewManager
    private let readerService: ReaderService
    private let reachability: Reachability
    private var isFetchingImage = false
    #if LCP
    private var didPrefetchLCPStreaming = false
    #endif

    var statePublisher = PassthroughSubject<Bool, Never>()
    @Published private(set) var state: BookCellState

    @Published var book: TPPBook {
        didSet {
            if book.identifier != currentBookIdentifier {
                currentBookIdentifier = book.identifier
                loadBookCoverImage()
            }
        }
    }

    @Published var isManagingHold: Bool = false

    @Published private(set) var stableButtonState: BookButtonState = .unsupported {
        didSet {
            // Always update state when stableButtonState changes - avoids comparison edge cases
            let newState = BookCellState(stableButtonState)
            state = newState
        }
    }
    @Published private(set) var registryState: TPPBookState
    @Published private var localBookStateOverride: TPPBookState?
    @Published var showHalfSheet: Bool = false

    var title: String { book.title }
    var authors: String { book.authors ?? "" }
    var showUnreadIndicator: Bool {
        if case .normal(let bookState) = state, bookState == .downloadSuccessful {
            return true
        } else {
            return false
        }
    }

    var buttonTypes: [BookButtonType] {
        if localBookStateOverride == .returning { return BookButtonState.returning.buttonTypes(book: book) }
        return stableButtonState.buttonTypes(book: book)
    }

    // MARK: - Initializer

    /// Convenience: builds a BookCellModel from the standard AppContainer graph.
    convenience init(book: TPPBook, appContainer: AppContainer) {
        self.init(
            book: book,
            imageCache: appContainer.imageCache,
            bookRegistry: appContainer.bookRegistry,
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            reachability: appContainer.reachability
        )
    }

    /// Creates a BookCellModel with explicit injectable dependencies for tests.
    /// Production code should prefer `init(book:appContainer:)`.
    init(
        book: TPPBook,
        imageCache: ImageCacheType,
        bookRegistry: TPPBookRegistryProvider,
        downloadCenter: MyBooksDownloadCenter,
        accountsManager: AccountsManager,
        samplePreviewManager: SamplePreviewManager,
        readerService: ReaderService,
        reachability: Reachability = AppContainer.production().reachability
    ) {
        self.book = book
        self.bookRegistry = bookRegistry
        self.downloadCenter = downloadCenter
        self.accountsManager = accountsManager
        self.samplePreviewManager = samplePreviewManager
        self.readerService = readerService
        self.reachability = reachability
        self.isLoading = bookRegistry.processing(forIdentifier: book.identifier)
        self.currentBookIdentifier = book.identifier
        self.imageCache = imageCache

        // Get registry state and compute initial button state from it
        let currentRegistryState = bookRegistry.state(for: book.identifier)
        self.registryState = currentRegistryState

        // Compute initial button state from registry state (not just book data)
        let initialButtonState = Self.computeButtonState(
            book: book,
            registryState: currentRegistryState,
            isManagingHold: false,
            override: nil,
            bookRegistry: bookRegistry
        )
        self.stableButtonState = initialButtonState
        // Initialize state from computed button state (didSet doesn't fire during init)
        self.state = BookCellState(initialButtonState)

        self.image = generatePlaceholder(for: book)
        registerForNotifications()
        loadBookCoverImage()
        bindRegistryState()
        bindReachability()
        setupStableButtonState()
        #if LCP
        prefetchLCPStreamingIfPossible()
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Image Loading

    private func generatePlaceholder(for book: TPPBook) -> UIImage {
        let size = CGSize(width: 80, height: 120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { ctx in
                if let view = NYPLTenPrintCoverView(
                    frame: CGRect(origin: .zero, size: size),
                    withTitle: book.title,
                    withAuthor: book.authors ?? "Unknown Author",
                    withScale: 0.4
                ) {
                    view.layer.render(in: ctx.cgContext)
                }
            }
    }

    func loadBookCoverImage() {
        let simpleKey = book.identifier
        let thumbnailKey = "\(book.identifier)_thumbnail"

        if let cachedImage = imageCache.get(for: simpleKey) ?? imageCache.get(for: thumbnailKey) {
            image = cachedImage
        } else if let registryImage = bookRegistry.cachedThumbnailImage(for: book) {
            setImageAndCache(registryImage)
        } else {
            fetchAndCacheImage()
        }
    }

    private func fetchAndCacheImage() {
        guard !isFetchingImage else { return }
        isFetchingImage = true
        isLoading = true

        bookRegistry.thumbnailImage(for: self.book) { [weak self] fetchedImage in
            guard let self else { return }
            // Always clear loading state, even if image fetch failed
            self.isLoading = false
            self.isFetchingImage = false

            if let fetchedImage {
                self.setImageAndCache(fetchedImage)
            }
        }
    }

    private func setImageAndCache(_ image: UIImage) {
        let simpleKey = book.identifier
        let thumbnailKey = "\(book.identifier)_thumbnail"
        imageCache.set(image, for: simpleKey)
        imageCache.set(image, for: thumbnailKey)
        self.image = image
    }

    // MARK: - Notification Handling

    private func registerForNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(updateButtons),
                                               name: .TPPReachabilityChanged, object: nil)
    }

    private func bindRegistryState() {
        bookRegistry.bookStatePublisher
            .filter { [weak self] in $0.0 == self?.book.identifier }
            .map { $0.1 }
            .receive(on: RunLoop.main) // Use RunLoop.main to avoid "Publishing changes during view updates"
            .sink { [weak self] newState in
                guard let self else { return }

                // Update book from registry so availability data (hold position
                // loan duration, etc.) is current. Without this, views like holdingInfoView
                // read stale data from the pre-borrow catalog book.
                if let updatedBook = self.bookRegistry.book(forIdentifier: self.book.identifier) {
                    self.book = updatedBook
                }

                self.registryState = newState

                // Clear loading state based on state transitions.
                // Exhaustive (no `default:`) — F-011 class-of-bug guard.
                // Compiler flags this site if TPPBookState gains a case, so
                // a new completed/terminal state can't silently leave the
                // cell stuck with isLoading=true.
                switch newState {
                case .downloading, .downloadFailed, .downloadSuccessful, .holding, .unregistered:
                    // These states indicate the action completed - clear loading
                    self.isLoading = false
                case .downloadNeeded, .returning, .used, .unsupported, .SAMLStarted:
                    break
                }
            }
            .store(in: &cancellables)

        // Subscribe to download errors so the half sheet can present them via SwiftUI .alert.
        // Filter by error kind: borrow errors only show for unregistered books (user tapped Get),
        // download errors only for books in download-related states.
        downloadCenter.downloadErrorPublisher
            .filter { [weak self] in $0.bookId == self?.book.identifier }
            .filter { [weak self] errorInfo in
                guard let self else { return true }
                switch errorInfo.kind {
                case .borrow:
                    return self.registryState == .unregistered || self.registryState == .holding
                case .download:
                    return self.registryState == .downloading || self.registryState == .downloadFailed
                        || self.registryState == .downloadNeeded
                case .general:
                    return true
                }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorInfo in
                guard let self else { return }

                let alertModel: AlertModel
                if let retryAction = errorInfo.retryAction {
                    alertModel = .retryable(
                        title: errorInfo.title,
                        message: errorInfo.message,
                        retryAction: retryAction
                    )
                } else {
                    alertModel = AlertModel(
                        title: errorInfo.title,
                        message: errorInfo.message,
                        buttonTitle: Strings.Generic.ok
                    )
                }

                // If the half sheet is visible, present there. Otherwise present from
                // the cell-level alert so list users still get an immediate popup.
                if self.showHalfSheet {
                    self.downloadErrorAlert = alertModel
                    self.showAlert = nil
                } else {
                    self.showAlert = alertModel
                    self.downloadErrorAlert = nil
                }
            }
            .store(in: &cancellables)
    }

    private func computeButtonState(book: TPPBook, registryState: TPPBookState, isManagingHold: Bool, override: TPPBookState?) -> BookButtonState {
        return Self.computeButtonState(book: book, registryState: registryState, isManagingHold: isManagingHold, override: override, bookRegistry: bookRegistry)
    }

    /// Static version for use during initialization
    private static func computeButtonState(book: TPPBook, registryState: TPPBookState, isManagingHold: Bool, override: TPPBookState?, bookRegistry: TPPBookRegistryProvider) -> BookButtonState {
        // Honor the in-flight UI override (currently used for .returning so the
        // cell shows "Returning…" between the user confirming the return and the
        // registry transitioning to .unregistered after the network round-trip
        // + bookmark deletion + post-return sync). Without this the button keeps
        // showing the pre-return state (Read/Return) until the registry finally
        // flips, which the user perceives as "tap did nothing" (F-017).
        if override == .returning {
            return .returning
        }
        let availability = book.defaultAcquisition?.availability
        // Only reflect actual download state from registry; do not treat UI image loading as download-in-progress
        let isProcessingDownload = registryState == .downloading
        if case .holding = registryState, isManagingHold { return .managingHold }
        return BookButtonMapper.map(
            registryState: registryState,
            availability: availability,
            isProcessingDownload: isProcessingDownload
        )
    }

    private func setupStableButtonState() {
        Publishers.CombineLatest4($book, $registryState, $isManagingHold, $localBookStateOverride)
            .map { [weak self] book, state, isManaging, override in
                self?.computeButtonState(book: book, registryState: state, isManagingHold: isManaging, override: override) ?? .unsupported
            }
            .removeDuplicates()
            // Use throttle instead of debounce - throttle emits immediately on first value,
            // then emits the latest value after the interval. Debounce waits for silence.
            .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
            .assign(to: &$stableButtonState)
    }

    /// react to mid-flight network drops. The pre-flight check on
    /// Download/Reserve handles the cold-offline tap; this subscription
    /// handles the case where reachability drops AFTER the user already
    /// kicked off a borrow/download (so isLoading is true and the spinner
    /// would otherwise sit there for ~60s waiting on URLSession's timeout).
    /// `dropFirst()` skips the CurrentValueSubject's replay so we only act
    /// on actual transitions.
    private func bindReachability() {
        reachability.connectivityPublisher
            .dropFirst()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isLoading else { return }
                self.isLoading = false
                self.presentOfflineAlert()
            }
            .store(in: &cancellables)
    }

    private func presentOfflineAlert() {
        // The retry routes back through `callDelegate(for: .download)` (not
        // straight into `didSelectDownload`) so the pre-flight reachability
        // check fires again. If the user taps Retry while still offline, the
        // alert reappears — same UX as a fresh tap, no spinner-of-death.
        let alert = AlertModel.retryable(
            title: Strings.MyDownloadCenter.noConnectionTitle,
            message: Strings.MyDownloadCenter.noConnectionMessage,
            retryAction: { [weak self] in self?.callDelegate(for: .download) }
        )
        if showHalfSheet {
            downloadErrorAlert = alert
            showAlert = nil
        } else {
            showAlert = alert
            downloadErrorAlert = nil
        }
    }

    // MARK: - State Consistency Validation

    /// Validates that the model's state is consistent with the registry.
    /// This is useful for debugging state inconsistency issues.
    ///
    /// - Returns: true if state is consistent, false if there's a mismatch
    @discardableResult
    func validateStateConsistency() -> Bool {
        let currentRegistryState = bookRegistry.state(for: book.identifier)
        let expectedButtonState = computeButtonState(book: book, registryState: currentRegistryState, isManagingHold: isManagingHold, override: localBookStateOverride)

        let isConsistent = stableButtonState == expectedButtonState && registryState == currentRegistryState

        #if DEBUG
        if !isConsistent {
            Log.warn(#file, """
        ⚠️ STATE INCONSISTENCY DETECTED for '\(book.title)'
        Book ID: \(book.identifier)
        Model registryState: \(registryState.stringValue())
        Actual registryState: \(currentRegistryState.stringValue())
        Model buttonState: \(stableButtonState)
        Expected buttonState: \(expectedButtonState)
        """)

            // Track for analytics
            TPPErrorLogger.logError(
                withCode: .bookStateInconsistency,
                summary: "BookCellModel state mismatch",
                metadata: [
                    "bookId": book.identifier,
                    "bookTitle": book.title,
                    "modelRegistryState": registryState.stringValue(),
                    "actualRegistryState": currentRegistryState.stringValue(),
                    "modelButtonState": String(describing: stableButtonState),
                    "expectedButtonState": String(describing: expectedButtonState)
                ]
            )
        }
        #endif

        return isConsistent
    }

    @objc private func updateButtons() {
        Task { @MainActor [weak self] in
            self?.isLoading = false
        }
    }
}

extension BookCellModel {
    func callDelegate(for action: BookButtonType) {
        // pre-flight: Download/Retry/Get/Reserve all hit the network
        // (borrow → fulfillment → download). If we're offline, surface the
        // retryable no-connection alert instead of setting isLoading=true and
        // waiting ~60s for URLSession to time out (the original "stale button"
        // bug). Other actions (Read, Listen, Cancel, Return, Remove) are
        // either local or have their own confirmation paths and don't need
        // a connection to begin.
        // Exhaustive (no `default:`) — F-011 class-of-bug guard. Compiler
        // flags this site if BookButtonType gains a case, so a new
        // network-bound action can't silently skip the offline pre-flight.
        switch action {
        case .download, .retry, .get, .reserve:
            if !reachability.isConnectedToNetwork() {
                presentOfflineAlert()
                return
            }
        case .readStreaming:
            // PP-4161: streaming-media reader needs network too — the asset
            // is online-only. Same pre-flight as download/get so the user
            // doesn't tap through to a doomed WKWebView load.
            if !reachability.isConnectedToNetwork() {
                presentOfflineAlert()
                return
            }
        case .read, .listen, .cancel, .close, .sample, .audiobookSample,
             .remove, .cancelHold, .manageHold, .return, .returning:
            break
        }

        // Set loading state for actions that need it.
        // .return and .cancelHold are excluded here because they show a
        // confirmation alert first; loading starts only after the patron confirms.
        // Exhaustive (no `default:`) — F-011 class-of-bug guard.
        switch action {
        case .download, .retry, .get, .reserve, .remove, .returning, .cancel:
            isLoading = true
        case .read, .listen, .close, .sample, .audiobookSample,
             .cancelHold, .manageHold, .return, .readStreaming:
            // .readStreaming presents the reader directly — loading state is
            // owned by the StreamingReaderViewModel after presentation. No
            // cell-level spinner so the tap → present transition stays snappy.
            break
        }

        switch action {
        case .download, .retry, .get:
            // PP-4161 Wave 4 (Path X): streaming-HTML titles funnel through
            // didSelectDownload like every other content type.
            // DownloadStartDispatcher.processDownloadWithCredentials early-
            // returns for streamingHTML so the asset-download attempt is
            // suppressed; the registry transitions to .downloadNeeded via
            // processUnregisteredState's open-access branch, and the cell's
            // button set then surfaces [.readStreaming, .return] on next
            // render.
            didSelectDownload()
        case .reserve:
            didSelectReserve()
        case .return:
            showAlert = AlertModel(
                title: DisplayStrings.return,
                message: String(format: DisplayStrings.returnMessage, book.title),
                buttonTitle: DisplayStrings.return,
                primaryAction: { [weak self] in
                    self?.isManagingHold = false
                    self?.bookState = .returning
                    self?.didSelectReturn()
                },
                secondaryButtonTitle: Strings.Generic.cancel,
                secondaryAction: { [weak self] in self?.isLoading = false },
                isPrimaryDestructive: true
            )
        case .cancelHold:
            showAlert = AlertModel(
                title: DisplayStrings.removeHold,
                message: String(format: DisplayStrings.removeHoldMessage, book.title),
                buttonTitle: DisplayStrings.removeHold,
                primaryAction: { [weak self] in
                    self?.isManagingHold = false
                    self?.bookState = .returning
                    self?.didSelectReturn()
                },
                secondaryButtonTitle: Strings.Generic.cancel,
                secondaryAction: { [weak self] in self?.isLoading = false },
                isPrimaryDestructive: true
            )
        case .remove, .returning:
            // Local delete and in-progress indicator: no confirmation needed
            isManagingHold = false
            bookState = .returning
            didSelectReturn()
        case .manageHold:
            isManagingHold = true
            bookState = .holding
            showHalfSheet = true
        case .cancel:
            didSelectCancel()
            // Clear loading after a short delay for cancel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isLoading = false
            }
        case .sample, .audiobookSample:
            didSelectSample()
        case .read, .listen, .readStreaming:
            // PP-4161: all three terminal "open the content" actions funnel
            // through didSelectRead — the content-type switch inside picks
            // the right renderer.
            didSelectRead()
        case .close:
            return
        }
    }

    func didSelectRead() {
        guard acquireReaderPresentationLock() else {
            Log.debug(#file, "didSelectRead ignored — reader presentation already in flight")
            return
        }
        isLoading = true
        switch book.defaultBookContentType {
        case .epub:
            readerService.openEPUB(book)
            self.isLoading = false
        case .pdf:
            #if LCP
            if LCPPDFs.hasLCPAcquisition(book) {
                // LCP PDFs go through the Readium publication opener which
                // is async + heavy (LCP key derivation + asset retrieval).
                // Hold isLoading until the route is pushed so the cell
                // spinner stays visible while the user waits.
                readerService.openPDF(book) { [weak self] in
                    self?.isLoading = false
                }
                return
            }
            #endif
            guard let url = downloadCenter.fileUrl(for: book.identifier) else { self.isLoading = false; return }
            let metadata = TPPPDFDocumentMetadata(with: book)
            let document = TPPPDFDocument(url: url)
            if let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator {
                coordinator.storePDF(document: document, metadata: metadata, forBookId: book.identifier)
                coordinator.push(.pdf(BookRoute(id: book.identifier)))
            }
            self.isLoading = false
        case .audiobook:
            openAudiobookFromCell()
        case .streamingHTML:
            // PP-4161: streaming-media titles present via the
            // NavigationCoordinator's streamingHTML route. No on-disk asset,
            // no reader-service round-trip — just push the route and let
            // StreamingReaderView own the lifecycle from there.
            if let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator {
                coordinator.store(book: book)
                coordinator.push(.streamingHTML(BookRoute(id: book.identifier)))
            }
            self.isLoading = false
        default:
            self.isLoading = false
        }
    }

    /// Returns `true` if the caller may proceed with reader presentation.
    /// Returns `false` if a presentation is already in flight (rapid repeat tap).
    /// The lock auto-releases after `readerPresentationLockWindow` so the button
    /// stays usable for legitimate re-entry.
    func acquireReaderPresentationLock() -> Bool {
        guard !isPresentingReader else { return false }
        isPresentingReader = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readerPresentationLockWindow) { [weak self] in
            self?.isPresentingReader = false
        }
        return true
    }

    private func openAudiobookFromCell() {
        BookService.open(book) { [weak self] in
            self?.isLoading = false
        }
    }

    private func presentAudiobookFrom(json: [String: Any], decryptor: DRMDecryptor?) {
        BookService.open(book)
        self.isLoading = false
    }

    private func licenseURL(forBookIdentifier identifier: String) -> URL? {
        #if LCP
        guard let contentURL = downloadCenter.fileUrl(for: identifier) else { return nil }
        let license = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        return FileManager.default.fileExists(atPath: license.path) ? license : nil
        #else
        return nil
        #endif
    }

    #if LCP
    private func prefetchLCPStreamingIfPossible() {
        guard !didPrefetchLCPStreaming, LCPAudiobooks.canOpenBook(book) else { return }
        if let localURL = downloadCenter.fileUrl(for: book.identifier), FileManager.default.fileExists(atPath: localURL.path) {
            return
        }
        guard let license = licenseURL(forBookIdentifier: book.identifier), let lcpAudiobooks = LCPAudiobooks(for: license) else { return }
        didPrefetchLCPStreaming = true
        lcpAudiobooks.startPrefetch()
    }
    #endif

    func didSelectReturn() {
        self.isLoading = true
        let identifier = self.book.identifier
        downloadCenter.returnBook(withIdentifier: identifier) { [weak self] in
            // returnBook's completion is `@Sendable` (Swift 6 targeted, #1149), so it
            // runs in a nonisolated context; hop to the main actor to mutate this
            // @MainActor model's published UI state.
            Task { @MainActor in
                self?.isLoading = false
                self?.isManagingHold = false
                self?.showHalfSheet = false
            }
        }
    }

    func didSelectDownload() {
        let account = accountsManager.currentUserAccount
        if account.needsAuth && !account.hasCredentials() {
            // swarm_d8f11437 Module A wave 4 — migrated to AppContainer-
            // injected sheet presenter. accountsManager retained on the
            // post-dismiss closure side for the `hasCredentials()` gate.
            AppContainer.production().signInModalSheetPresenter
                .presentSignInModalForCurrentAccount { [weak self] in
                    guard let self else { return }
                    // Only proceed if user successfully logged in, not if they cancelled
                    guard accountsManager.currentUserAccount.hasCredentials() else {
                        Log.info(#file, "Sign-in cancelled or failed, not starting download")
                        return
                    }
                    self.startDownloadNow()
                }
            return
        }
        startDownloadNow()
    }

    private func startDownloadNow() {
        if case .canHold = state.buttonState {
            NotificationService.requestAuthorization()
        }
        downloadCenter.startDownload(for: book)
    }

    func didSelectReserve() {
        isLoading = true
        let account = accountsManager.currentUserAccount
        if account.needsAuth && !account.hasCredentials() {
            // swarm_d8f11437 Module A wave 4 — migrated to AppContainer-
            // injected sheet presenter.
            AppContainer.production().signInModalSheetPresenter
                .presentSignInModalForCurrentAccount { [weak self] in
                    guard let self else { return }
                    // Only proceed if user successfully logged in, not if they cancelled
                    guard accountsManager.currentUserAccount.hasCredentials() else {
                        Log.info(#file, "Sign-in cancelled or failed, not proceeding with reservation")
                        self.isLoading = false
                        return
                    }
                    NotificationService.requestAuthorization()
                    Task {
                        do {
                            _ = try await self.downloadCenter.borrowAsync(self.book, attemptDownload: false)
                        } catch {
                            Log.error(#file, "Failed to borrow book: \(error.localizedDescription)")
                        }
                        self.isLoading = false
                    }
                }
            return
        }
        NotificationService.requestAuthorization()
        Task {
            do {
                _ = try await downloadCenter.borrowAsync(book, attemptDownload: false)
            } catch {
                Log.error(#file, "Failed to borrow book: \(error.localizedDescription)")
            }
            self.isLoading = false
        }
    }

    func didSelectSample() {
        isLoading = true
        if book.defaultBookContentType == .audiobook {
            if book.sampleAcquisition?.type == "text/html" {
                samplePreviewManager.close()
                if let url = book.sampleAcquisition?.hrefURL,
                   let top = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() {
                    let safari = SFSafariViewController(url: url)
                    top.present(safari, animated: true)
                }
            } else {
                samplePreviewManager.toggle(for: book)
            }
            self.isLoading = false
            return
        }
        samplePreviewManager.close()
        EpubSampleFactory.createSample(book: book) { sampleURL, error in
            self.isLoading = false
            if let error = error {
                Log.debug("Sample generation error for \(self.book.title): \(error.localizedDescription)", "")
                return
            }
            if let sampleWebURL = sampleURL as? EpubSampleWebURL {
                if let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate, let top = appDelegate.topViewController() {
                    let safari = SFSafariViewController(url: sampleWebURL.url)
                    top.present(safari, animated: true)
                }
                return
            }
            if let url = sampleURL?.url {
                // Check if this is an EPUB sample
                let isEpubSample = self.book.sample?.type == .contentTypeEpubZip

                if isEpubSample {
                    // Use Readium EPUB reader for EPUB samples
                    self.readerService.openSample(self.book, url: url)
                } else {
                    // Use WebKit for HTML/web samples
                    let web = BundledHTMLViewController(fileURL: url, title: self.book.title)
                    if let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate, let top = appDelegate.topViewController() {
                        top.present(web, animated: true)
                    }
                }
            }
        }
    }

    func didSelectCancel() {
        downloadCenter.cancelDownload(for: book.identifier)
    }
}

extension BookCellModel: BookButtonProvider {
    func handleAction(for type: BookButtonType) {
        callDelegate(for: type)
    }

    func isProcessing(for type: BookButtonType) -> Bool {
        isLoading
    }
}

extension BookCellModel: HalfSheetProvider {
    var bookState: TPPBookState {
        get {
            localBookStateOverride ?? registryState
        }
        set {
            if newValue == .returning {
                localBookStateOverride = .returning
            } else {
                localBookStateOverride = nil
            }
        }
    }

    var buttonState: BookButtonState {
        let currentRegistryState = bookRegistry.state(for: book.identifier)
        let availability = book.defaultAcquisition?.availability
        let isDownloading = isLoading || currentRegistryState == .downloading
        return BookButtonMapper.map(
            registryState: currentRegistryState,
            availability: availability,
            isProcessingDownload: isDownloading
        )
    }

    var isFullSize: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var downloadProgress: Double {
        downloadCenter.downloadProgress(for: book.identifier)
    }
}
