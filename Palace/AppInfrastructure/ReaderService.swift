import UIKit
import Combine
import ReadiumShared
import ReadiumAdapterGCDWebServer
import PalaceLogging
#if LCP
import ReadiumLCP
#endif

final class ReaderService {
    init() {}

    private lazy var r3Owner: TPPR3Owner = TPPR3Owner()

    /// Stores Combine subscriptions observing re-download completion per book.
    /// Keyed by book identifier so concurrent open attempts don't clobber each other.
    private var redownloadObservers: [String: AnyCancellable] = [:]
    private var redownloadTimeouts: [String: Task<Void, Never>] = [:]

    /// Generation counter per book id. Bumped every time `openPDF` starts a
    /// new open and every time `releaseReadiumPDF` tears one down. The
    /// async `libraryService.openBook` completion captures the generation
    /// it was started under and bails out if it doesn't match — that's
    /// what prevents a stale callback from a back-and-forth re-entry
    /// storing the OLD publication on top of the NEW one (overlapping
    /// loads). Also keyed off in `openPDF` itself: if a generation is
    /// already in flight for this book, the second tap is coalesced.
    private var openGenerationByBookId: [String: Int] = [:]
    private var openInFlightBookIds: Set<String> = []

    private func topPresenter() -> UIViewController? {
        guard let root = UIApplication.shared.mainKeyWindow?.rootViewController else {
            Log.warn(#file, "No root view controller available — cannot present reader")
            return nil
        }
        var base: UIViewController = root
        while let presented = base.presentedViewController { base = presented }
        return base
    }

    /// Exposes the shared `GCDHTTPServer` so the PDF navigator (and any other
    /// Readium-backed view) can serve decrypted publication resources through
    /// the same server the EPUB path already uses — one server, one endpoint
    /// registry, one lifecycle.
    var httpServer: ReadiumAdapterGCDWebServer.GCDHTTPServer? {
        r3Owner.libraryService.httpServer
    }

    /// Tears down all in-memory state for an LCP-protected PDF: drops the
    /// `Publication` from the navigation coordinator, removes the
    /// `GCDHTTPServer` endpoint that was registered for the publication,
    /// and clears the pending-open marker. The TOC + page-count snapshot
    /// is intentionally preserved across this teardown so a re-open
    /// repopulates side panels instantly.
    @MainActor
    func releaseReadiumPDF(forBookIdentifier identifier: String) {
        // Bump the generation so any in-flight openBook completion still
        // pending for this book id no-ops when it fires — otherwise an
        // exit-and-re-enter can land the OLD publication into the
        // coordinator after the NEW open already started.
        openGenerationByBookId[identifier, default: 0] += 1
        openInFlightBookIds.remove(identifier)
        // Only clear the progress reporter if it was tracking this book.
        // A back-out from book A shouldn't wipe a parallel open for B.
        if LCPPDFOpenProgress.shared.bookIdentifier == identifier {
            LCPPDFOpenProgress.shared.finish()
        }
        r3Owner.libraryService.releaseServedPublication(forBookIdentifier: identifier)
        AppContainer.production().navigationCoordinatorHub.coordinator?
            .removeReadiumPDF(forBookId: identifier)
    }

    @MainActor
    func openEPUB(_ book: TPPBook) {
        // Polish-phase (in-app-nav-polish-2026-06-01): record wall-clock
        // open time so RecentlyReadingService's Continue Reading row
        // sort is correct. EPUB location JSON does NOT embed a
        // timeStamp; without this record the row falls back to
        // `book.updated` (OPDS catalog date) and shows the wrong book.
        AppContainer.production().bookOpenTracker.recordOpened(book.identifier)
        // Polish-phase ("should close" UX): switching from audiobook to
        // ebook fully closes the audiobook session — not just suppresses
        // the mini-player chrome. User explicitly asked for this: opening
        // the reader is a content-switch, not a side activity. The
        // audiobook can be re-opened from My Books to resume.
        Self.stopActiveAudiobookSessionIfNeeded()
        openEPUBInternal(book, isRetry: false)
    }

    /// Opens an LCP-protected PDF through the Readium pipeline:
    /// `AssetRetriever` + `PublicationOpener` → `Publication` served by
    /// `httpServer` → `PDFNavigatorViewController`. No temp-extract step.
    ///
    /// The route is pushed IMMEDIATELY so the reader view appears with
    /// its own loading state — the publication open + TOC pre-load run
    /// asynchronously in the background, and the reader view re-renders
    /// when the publication lands. This is intentional: LCP open on large
    /// Marketplace containers involves hundreds of synchronous AES decrypt
    /// calls (visible in `TPPLCPClient.swift: Successfully decrypted ...`
    /// logs) and can take 30-60s. Holding the user on the book detail
    /// page during that window makes the app feel frozen.
    ///
    /// `onFinish` fires once the route has been pushed (or the open has
    /// failed and an alert is queued). It does NOT wait for the
    /// publication itself — callers that want to clear a button spinner
    /// can do so as soon as the reader appears.
    /// LCP PDF open flow — **disk-extract architecture**.
    ///
    /// Previously this route handed an LCP-encrypted `Publication`
    /// directly to Readium's `PDFNavigatorViewController`, which did
    /// random-access reads on the encrypted stream. The device log
    /// captured 841,570 decrypts in 10s with ~9 KB retained per call
    /// (residentMB 1.8 → 2.8 GB), guaranteed OOM on anything bigger
    /// than a one-page PDF.
    ///
    /// The new path streams the decrypted PDF ONCE through Readium's
    /// `Resource.stream(consume:)` into a temp .pdf on disk, then
    /// renders with PDFKit (`TPPPDFReaderView`) which mmaps the file
    /// and pages in on demand. ~25k linear decrypts for a 50MB book
    /// instead of ~800k random-access ones, with the Readium
    /// publication released the instant extraction completes.
    ///
    /// Cached extract on disk → re-opens skip the decrypt entirely.
    @MainActor
    func openPDF(_ book: TPPBook, onFinish: (() -> Void)? = nil) {
        // Polish-phase (in-app-nav-polish-2026-06-01) — see openEPUB.
        AppContainer.production().bookOpenTracker.recordOpened(book.identifier)
        Self.stopActiveAudiobookSessionIfNeeded()
        guard let presenter = topPresenter() else { onFinish?(); return }

        if openInFlightBookIds.contains(book.identifier) {
            Log.info(#file, "[PERF] [LCP-PDF] open coalesced — already in flight for \(book.identifier)")
            onFinish?()
            return
        }
        openInFlightBookIds.insert(book.identifier)
        let generation = openGenerationByBookId[book.identifier, default: 0] + 1
        openGenerationByBookId[book.identifier] = generation

        let openStartedAt = Date()
        Log.info(#file, "[PERF] [LCP-PDF] T0 open requested: \(book.title) (\(book.identifier)) gen=\(generation), residentMB=\(Self.residentMemoryMB())")

        LCPPDFOpenProgress.shared.begin(bookIdentifier: book.identifier)
        LCPPDFOpenProgress.shared.setPhase(.openingPublication)

        // Pre-emptive memory release for the catalog / cell / cover caches.
        // The extraction itself is bounded (one chunk at a time + the
        // temp file) but giving Readium more headroom up front reduces
        // the chance of an OOM during the initial license-check phase
        // on smaller-RAM devices.
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator
        coordinator?.store(book: book)
        coordinator?.markReadiumPDFPending(forBookId: book.identifier)
        coordinator?.push(.pdf(BookRoute(id: book.identifier)))
        Log.info(#file, "[PERF] [LCP-PDF] T1 route pushed (+\(Self.ms(since: openStartedAt))ms)")
        onFinish?()

        #if LCP
        // Disk cache hit: a prior extract is reusable as long as the
        // loan hasn't been returned (LocalBookContentService invalidates
        // on return). Skip the entire Readium open + decrypt pass.
        if let accountId = AppContainer.production().accountsManager.currentAccountId,
           let cachedURL = LCPPDFDiskExtract.cachedURL(bookIdentifier: book.identifier, account: accountId) {
            Log.info(#file, "[PERF] [LCP-PDF] disk-extract cache hit — opening PDFKit directly: \(cachedURL.lastPathComponent)")
            self.handOffExtractedPDF(at: cachedURL, for: book, openStartedAt: openStartedAt)
            return
        }
        #endif

        // Periodic memory log + runaway-abort safety net. With the
        // disk-extract path the decrypt count should peak in the
        // low tens of thousands (one decrypt per LCP block as the
        // stream advances through the publication), so 150k is still
        // way above any healthy open and below the OOM ceiling.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while await LCPPDFOpenProgress.shared.phase != .idle {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let mb = Self.residentMemoryMB()
                let blocks = await LCPPDFOpenProgress.shared.decryptedBlocks
                let bytes = await LCPPDFOpenProgress.shared.bytesExtracted
                let total = await LCPPDFOpenProgress.shared.totalExtractBytes
                let phase = await LCPPDFOpenProgress.shared.phase
                Log.info(#file, "[PERF] [LCP-PDF] residentMB=\(mb) blocks=\(blocks) extracted=\(bytes)/\(total) phase=\(phase)")

                if blocks > 150_000 {
                    Log.error(#file, "[PERF] [LCP-PDF] abort: decrypt walk exceeded 150k blocks (\(blocks)) — aborting to avoid OOM")
                    await self.abortRunawayOpen(for: book)
                    return
                }
            }
        }

        let libraryOpenStartedAt = Date()
        r3Owner.libraryService.openBook(book, sender: presenter) { [weak self] result in
            let libraryOpenElapsedMs = Self.ms(since: libraryOpenStartedAt)
            switch result {
            case .success(let publication):
                Task { @MainActor in
                    guard let self else { return }
                    let currentGeneration = self.openGenerationByBookId[book.identifier, default: 0]
                    guard currentGeneration == generation else {
                        Log.info(#file, "[PERF] [LCP-PDF] stale openBook completion ignored for \(book.identifier) (gen=\(generation) current=\(currentGeneration))")
                        return
                    }
                    Log.info(#file, "[PERF] [LCP-PDF] T2 publication opened (+\(Self.ms(since: openStartedAt))ms total, libraryService.openBook=\(libraryOpenElapsedMs)ms)")
                    LCPPDFOpenProgress.shared.setPhase(.extractingToDisk)

                    #if LCP
                    guard let accountId = AppContainer.production().accountsManager.currentAccountId else {
                        Log.error(#file, "[PERF] [LCP-PDF] no current account — cannot resolve extract path")
                        await self.abortRunawayOpen(for: book)
                        return
                    }
                    // Disk-extract on a background task — chunk writes
                    // to FileHandle on a userInitiated queue, the main
                    // actor only sees progress publishes via
                    // LCPPDFOpenProgress.shared. The Readium publication
                    // is released the instant extraction completes —
                    // its job is to provide the decrypt context, and
                    // PDFKit owns the rendering surface from there.
                    let bookIdentifier = book.identifier
                    Task.detached(priority: .userInitiated) {
                        do {
                            let extractStartedAt = Date()
                            let extractedURL = try await LCPPDFDiskExtract.extract(
                                publication: publication,
                                bookIdentifier: bookIdentifier,
                                account: accountId
                            )
                            let extractMs = Self.ms(since: extractStartedAt)
                            await MainActor.run {
                                // Stale-completion guard again — user
                                // may have backed out during extract.
                                let cur = self.openGenerationByBookId[bookIdentifier, default: 0]
                                guard cur == generation else {
                                    Log.info(#file, "[PERF] [LCP-PDF] stale extract completion ignored for \(bookIdentifier)")
                                    return
                                }
                                Log.info(#file, "[PERF] [LCP-PDF] T3 extracted+ready (+\(Self.ms(since: openStartedAt))ms total, extract=\(extractMs)ms)")
                                // Release Readium publication — its work
                                // is done, free its memory now.
                                self.r3Owner.libraryService.releaseServedPublication(forBookIdentifier: bookIdentifier)
                                self.handOffExtractedPDF(at: extractedURL, for: book, openStartedAt: openStartedAt)
                            }
                        } catch {
                            Log.error(#file, "[PERF] [LCP-PDF] extract failed: \(error)")
                            await MainActor.run {
                                self.r3Owner.libraryService.releaseServedPublication(forBookIdentifier: bookIdentifier)
                                self.abortRunawayOpen(for: book)
                            }
                        }
                    }
                    #else
                    // Non-LCP build (open-source) — should never reach
                    // here because openPDF is only invoked for LCP books,
                    // but bail safely if it does.
                    self.r3Owner.libraryService.releaseServedPublication(forBookIdentifier: book.identifier)
                    self.abortRunawayOpen(for: book)
                    #endif
                }
            case .failure(let error):
                Task { @MainActor in
                    guard let self else { return }
                    self.openInFlightBookIds.remove(book.identifier)
                    self.presentOpenFailureAlert(for: error, book: book, isRetry: false)
                    coordinator?.removeReadiumPDF(forBookId: book.identifier)
                    if let path = coordinator?.path, path.count > 0 {
                        coordinator?.path.removeLast()
                    }
                    LCPPDFOpenProgress.shared.finish()
                }
            }
        }
    }

    /// Stores the extracted on-disk PDF into the coordinator's plain-PDF
    /// slot so `NavigationHostView` swaps the loading overlay out for
    /// `TPPPDFReaderView` (PDFKit). Clears the pending flag, finishes
    /// the progress reporter, and removes the in-flight bookkeeping.
    @MainActor
    private func handOffExtractedPDF(at url: URL, for book: TPPBook, openStartedAt: Date) {
        let document = TPPPDFDocument(url: url)
        let metadata = TPPPDFDocumentMetadata(with: book)
        let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator
        coordinator?.storePDF(document: document, metadata: metadata, forBookId: book.identifier)
        coordinator?.removeReadiumPDF(forBookId: book.identifier)  // clears pending + drops any Readium publication leftovers
        openInFlightBookIds.remove(book.identifier)
        LCPPDFOpenProgress.shared.finish()
        Log.info(#file, "[PERF] [LCP-PDF] T4 PDFKit handoff (+\(Self.ms(since: openStartedAt))ms total)")
    }

    /// Flattens a Readium publication's `[Link]` table of contents into a
    /// `[TPPPDFLocation]` array, resolving each link's destination to a
    /// 0-indexed page number via the publication's positions list.
    /// Returns `[]` if either call fails — the chrome handles an empty
    /// TOC gracefully (just no list items).
    private static func loadTableOfContents(for publication: Publication) async -> [TPPPDFLocation] {
        let tocResult = await publication.tableOfContents()
        guard case .success(let links) = tocResult else {
            return []
        }
        let positionsResult = await publication.positions()
        let positions: [Locator]
        switch positionsResult {
        case .success(let value): positions = value
        case .failure: positions = []
        }
        var out: [TPPPDFLocation] = []
        flatten(links: links, level: 0, positions: positions, into: &out)
        return out
    }

    private static func flatten(links: [ReadiumShared.Link],
                                 level: Int,
                                 positions: [Locator],
                                 into result: inout [TPPPDFLocation]) {
        for link in links {
            let pageNumber = pageNumber(for: link, positions: positions)
            result.append(
                TPPPDFLocation(
                    title: link.title,
                    subtitle: nil,
                    pageLabel: nil,
                    pageNumber: pageNumber,
                    level: level
                )
            )
            if !link.children.isEmpty {
                flatten(links: link.children, level: level + 1, positions: positions, into: &result)
            }
        }
    }

    /// Resolves a Readium `Link` to a 0-indexed page number. Falls back
    /// to matching the link's href against the publication's positions
    /// via stable string representation. Worst case: TOC entry jumps to
    /// page 0.
    private static func pageNumber(for link: ReadiumShared.Link, positions: [Locator]) -> Int {
        let linkHrefDesc = String(describing: link.href)
        if let matchIndex = positions.firstIndex(where: { String(describing: $0.href) == linkHrefDesc }) {
            return matchIndex
        }
        return 0
    }

    private static func loadPageCount(for publication: Publication) async -> Int {
        let result = await publication.positions()
        if case .success(let value) = result {
            return value.count
        }
        return 0
    }

    /// Milliseconds elapsed since the given timestamp. Used by the
    /// `[PERF] [LCP-PDF]` log markers — a single grep over the
    /// Console log after a test run produces a per-stage breakdown
    /// without needing Instruments / WDA. Cheap rounded integer so
    /// the log line stays compact.
    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Resident memory in MB, read from `mach_task_basic_info`. Used in
    /// `[PERF] [LCP-PDF]` log lines to spot the open phase that pushes
    /// the device over its jetsam ceiling — large LCP PDFs OOM'd on
    /// device before we added the catalog pre-emptive clear, and the
    /// log signal is what lets us tell whether the remaining pressure
    /// is from PDFNavigator buffers, the decrypt cache, or something
    /// upstream.
    /// Tears down an LCP-PDF open that's spiraling into OOM territory
    /// and surfaces a user-facing alert. Triggered by the periodic
    /// memory-log Task when the decrypt count crosses an absurd
    /// threshold — at that point the open is definitely not going to
    /// succeed and continuing risks a hard jetsam kill (worse UX than
    /// a clean alert).
    @MainActor
    private func abortRunawayOpen(for book: TPPBook) {
        releaseReadiumPDF(forBookIdentifier: book.identifier)
        let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator
        if let path = coordinator?.path, path.count > 0 {
            coordinator?.path.removeLast()
        }
        guard let top = topPresenter() else { return }
        let alert = UIAlertController(
            title: NSLocalizedString("Unable to open book", comment: ""),
            message: NSLocalizedString("This book is too large to open on this device right now. We're working on a fix — please contact support if this keeps happening.", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        top.present(alert, animated: true)
        TPPErrorLogger.logError(
            withCode: .lcpDRMFulfillmentFail,
            summary: "LCP PDF open aborted due to runaway decrypt",
            metadata: [
                "bookTitle": book.title,
                "bookIdentifier": book.identifier,
                "decryptedBlocks": LCPPDFOpenProgress.shared.decryptedBlocks,
                "residentMB": Self.residentMemoryMB()
            ]
        )
    }

    static func residentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size / (1024 * 1024))
    }

    @MainActor
    private func openEPUBInternal(_ book: TPPBook, isRetry: Bool) {
        guard let presenter = topPresenter() else { return }
        r3Owner.libraryService.openBook(book, sender: presenter) { result in
            switch result {
            case .success(let publication):
                if let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator {
                    coordinator.store(book: book)
                    coordinator.storeEPUBPublication(publication, forBookId: book.identifier, forSample: false)
                    coordinator.push(.epub(BookRoute(id: book.identifier)))
                } else {
                    let nav = UINavigationController()
                    self.r3Owner.readerModule.presentPublication(publication, book: book, in: nav, forSample: false)
                    TPPPresentationUtils.safelyPresent(nav, animated: true, completion: nil)
                }
            case .failure(let error):
                self.presentOpenFailureAlert(for: error, book: book, isRetry: isRetry)
            }
        }
    }

    @MainActor
    func openSample(_ book: TPPBook, url: URL) {
        guard let presenter = topPresenter() else { return }
        r3Owner.libraryService.openSample(book, sampleURL: url, sender: presenter) { result in
            switch result {
            case .success(let publication):
                if let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator {
                    coordinator.store(book: book)
                    coordinator.presentEPUBSample(publication, forBookId: book.identifier)
                } else {
                    let nav = UINavigationController()
                    self.r3Owner.readerModule.presentPublication(publication, book: book, in: nav, forSample: true)
                    TPPPresentationUtils.safelyPresent(nav, animated: true, completion: nil)
                }
            case .failure(let error):
                // Samples are not owned loans — no cleanup needed on failure.
                let alert = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
                TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
            }
        }
    }

    /// Presents the appropriate response for a failed book open.
    ///
    /// Priority order:
    /// 1. Definitive DRM status errors (expired/returned/revoked/cancelled) → show error
    ///    immediately; re-downloading cannot fix a genuinely revoked license.
    /// 2. First open attempt for any other error → log to Crashlytics, transparently delete
    ///    the local file and trigger a fresh download, then retry opening once.
    /// 3. Retry attempt or download failure → show "Content Protection Error" alert.
    @MainActor
    private func presentOpenFailureAlert(for error: LibraryServiceError, book: TPPBook, isRetry: Bool = false) {
        let inner: Error?
        if case .openFailed(let e) = error { inner = e } else { inner = nil }

        // Definitive license status errors (expired, returned, revoked, cancelled) cannot
        // be resolved by re-downloading — the server will reject the request. Show the
        // error immediately and let the patron manage the loan manually.
        #if LCP
        if let lcpError = inner as? LCPError,
           case .licenseStatus = lcpError {
            showContentProtectionError(for: error)
            return
        }
        #endif

        // Log every Content Protection Error to Crashlytics so future occurrences are
        // traceable with the specific LCPError type.
        TPPErrorLogger.logError(
            withCode: .lcpPassphraseRetrievalFail,
            summary: "Content Protection Error",
            metadata: [
                "bookTitle": book.title,
                "bookIdentifier": book.identifier,
                "lcpError": (inner ?? error).localizedDescription,
                "isRetry": isRetry
            ]
        )

        // On the first attempt, transparently clear the local file and re-download before
        // surfacing the error. This resolves corrupted or missing local EPUB/LCPL files
        // without requiring any action from the patron.
        if !isRetry {
            Log.info(#file, "Content Protection Error on first open — attempting transparent re-download for '\(book.title)'")
            attemptRedownloadAndReopen(book: book, originalError: error)
            return
        }

        showContentProtectionError(for: error)
    }

    /// Deletes the local file, resets the book state to `.downloadNeeded`, starts a fresh
    /// download, and retries opening once it completes. Falls back to the error alert if the
    /// download fails or takes longer than 120 seconds.
    @MainActor
    private func attemptRedownloadAndReopen(book: TPPBook, originalError: LibraryServiceError) {
        AppContainer.production().downloadCenter.deleteLocalContent(for: book.identifier)
        AppContainer.production().bookRegistry.setState(.downloadNeeded, for: book.identifier)

        let showFallback = { [weak self] in
            self?.cancelRedownload(for: book.identifier)
            self?.showContentProtectionError(for: originalError)
        }

        // 120-second safety timeout in case the download stalls.
        redownloadTimeouts[book.identifier] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled else { return }
            Log.warn(#file, "Re-download timed out for '\(book.title)' — showing Content Protection Error")
            await MainActor.run { showFallback() }
        }

        redownloadObservers[book.identifier] = AppContainer.production().bookRegistry.bookStatePublisher
            .filter { identifier, _ in identifier == book.identifier }
            .sink { [weak self] _, state in
                guard let self else { return }
                // Exhaustive (no `default:`) — F-011 class-of-bug guard. The
                // Swift compiler now flags this site if TPPBookState gains a
                // new case, so a re-download terminal state can't be silently
                // ignored. Non-terminal states (in-flight progress) are no-ops
                // here; only .downloadSuccessful/.downloadFailed end the wait.
                switch state {
                case .downloadSuccessful:
                    self.cancelRedownload(for: book.identifier)
                    Log.info(#file, "Re-download succeeded — retrying open for '\(book.title)'")
                    self.openEPUBInternal(book, isRetry: true)
                case .downloadFailed:
                    Log.error(#file, "Re-download failed for '\(book.title)' — showing Content Protection Error")
                    showFallback()
                case .unregistered, .downloadNeeded, .downloading, .returning,
                     .holding, .used, .unsupported, .SAMLStarted:
                    break
                }
            }

        AppContainer.production().downloadCenter.startDownload(for: book)
    }

    @MainActor
    private func cancelRedownload(for bookIdentifier: String) {
        redownloadObservers.removeValue(forKey: bookIdentifier)
        redownloadTimeouts[bookIdentifier]?.cancel()
        redownloadTimeouts.removeValue(forKey: bookIdentifier)
    }

    @MainActor
    private func showContentProtectionError(for error: LibraryServiceError) {
        let alert = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
    }

    // MARK: - View Controller Creation (for SwiftUI integration)

    /// Creates an EPUB view controller from a publication (used by EPUBReaderView)
    @MainActor
    func makeEPUBViewController(for publication: Publication, book: TPPBook, forSample: Bool, bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry) async throws -> UIViewController {
        let bookRegistry = bookRegistry

        // Sync reading position with server before opening (shows "Stay or Move"
        // dialog when the server has a different position from another device).
        // Samples don't need sync since they have no persisted position.
        if !forSample {
            let synchronizer = TPPLastReadPositionSynchronizer(bookRegistry: bookRegistry)
            let deviceID = AppContainer.production().accountsManager.currentUserAccount.deviceID
            await synchronizer.sync(for: publication, book: book, drmDeviceID: deviceID)
        }

        // Re-read location after sync — it may have been updated if user chose "Move"
        let lastSavedLocation = bookRegistry.location(forIdentifier: book.identifier)
        let initialLocator = await lastSavedLocation?.convertToLocator(publication: publication)

        guard let readerModule = r3Owner.readerModule as? ReaderModule else {
            throw ReaderError.formatNotSupported
        }

        let formatModule = readerModule.formatModules.first { $0.supports(publication) }
        guard let epubModule = formatModule else {
            throw ReaderError.formatNotSupported
        }

        let readerVC = try await epubModule.makeReaderViewController(
            for: publication,
            book: book,
            initialLocation: initialLocator,
            forSample: forSample
        )

        readerVC.hidesBottomBarWhenPushed = true
        return readerVC
    }

    // MARK: - Polish-phase: stop audiobook on reader open

    /// Called from `openEPUB(_:)` / `openPDF(_:onFinish:)` to terminate
    /// any in-flight audiobook session BEFORE pushing the reader. The
    /// user explicitly requested this behavior (vs the prior chrome-only
    /// suppression): switching from an audiobook to an ebook is a
    /// content-switch, not a side activity — the audio session fully
    /// closes (player unloaded, mini-player + full player removed, Now
    /// Playing chrome cleared, presenter `clearActiveSession` fires).
    /// The audiobook can be re-opened from My Books to resume from the
    /// last-saved position.
    ///
    /// No-op when there's no active session. Fires
    /// `stopPlayback(dismissPhoneUI: true, persistFinalPosition: true)`
    /// so the user's listening position is saved before tear-down.
    @MainActor
    private static func stopActiveAudiobookSessionIfNeeded() {
        let session = AppContainer.production().audiobookSession
        guard session.state.isActive else { return }
        Task { @MainActor in
            await session.stopPlayback(
                dismissPhoneUI: true,
                persistFinalPosition: true
            )
        }
    }
}
