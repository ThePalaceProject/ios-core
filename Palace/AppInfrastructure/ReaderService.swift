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
    @MainActor
    func openPDF(_ book: TPPBook, onFinish: (() -> Void)? = nil) {
        guard let presenter = topPresenter() else { onFinish?(); return }

        // Coalesce: if an open is already in flight for this book id, the
        // second tap is a no-op rather than starting a parallel decrypt.
        // Without this guard a double-tap on the Read button (or a swipe-
        // back-and-re-tap before the first open finishes) spins up two
        // concurrent libraryService.openBook flows, both holding the
        // publication and both running the cross-ref AES decrypt walk.
        if openInFlightBookIds.contains(book.identifier) {
            Log.info(#file, "[PERF] [LCP-PDF] open coalesced — already in flight for \(book.identifier)")
            onFinish?()
            return
        }
        openInFlightBookIds.insert(book.identifier)
        let generation = openGenerationByBookId[book.identifier, default: 0] + 1
        openGenerationByBookId[book.identifier] = generation

        // [PERF] T0: Read button tapped → route push completion. Sets
        // the baseline for downstream stage timings so a single grep
        // over the log produces a per-stage breakdown.
        let openStartedAt = Date()
        Log.info(#file, "[PERF] [LCP-PDF] T0 open requested: \(book.title) (\(book.identifier)) gen=\(generation), residentMB=\(Self.residentMemoryMB())")

        LCPPDFOpenProgress.shared.begin(bookIdentifier: book.identifier)
        LCPPDFOpenProgress.shared.setPhase(.openingPublication)

        // Periodically log memory while the open is in flight so a
        // post-mortem on an OOM crash can identify which phase tipped
        // the device over its jetsam ceiling. Also acts as our
        // last-line-of-defense abort: if the decrypt walk runs away
        // (a known failure mode on large Marketplace LCP PDFs where
        // PDFNavigator's random-access reads hit unique file offsets
        // and the cache never catches up), we pop the route and
        // surface a friendly alert before the OS jetsam-kills the
        // app. 150k decrypts is conservatively above any healthy
        // open — a typical small PDF first-page paints in 200-2000
        // decrypts.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while await LCPPDFOpenProgress.shared.phase != .idle {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let mb = Self.residentMemoryMB()
                let blocks = await LCPPDFOpenProgress.shared.decryptedBlocks
                let hits = await LCPPDFOpenProgress.shared.cachedHits
                let phase = await LCPPDFOpenProgress.shared.phase
                Log.info(#file, "[PERF] [LCP-PDF] residentMB=\(mb) blocks=\(blocks) cacheHits=\(hits) phase=\(phase)")

                if blocks > 150_000 {
                    Log.error(#file, "[PERF] [LCP-PDF] abort: decrypt walk exceeded 150k blocks (\(blocks)) — assuming runaway, aborting open to avoid OOM")
                    await self.abortRunawayOpen(for: book)
                    return
                }
            }
        }

        // LCP-PDF open on large Marketplace containers walks the PDF
        // cross-ref table through the LCP decrypt layer (hundreds of
        // `Successfully decrypted 2064 -> 2048` calls in the log), which
        // is memory-hungry. On a device that's already holding the
        // catalog memory cache (3+ MB of OPDS JSON for the active +
        // preloaded entry points) plus the book-cell model cache, the
        // combined working set can trip the OS memory limit and OOM.
        // Post the system memory-warning notification proactively so
        // every cache that listens (CatalogRepository, BookCellModelCache,
        // image caches) drops its in-memory contents before the decrypt
        // walk starts. Disk caches survive — the catalog's URLCache is
        // content-addressed, so the next time the user backs out the
        // feed re-hydrates from disk without a network round-trip.
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator
        coordinator?.store(book: book)
        coordinator?.markReadiumPDFPending(forBookId: book.identifier)

        // Cold-app cache hit: if a previous session persisted TOC + page
        // count to disk, surface it BEFORE the publication opens so side
        // panels populate the instant the navigator appears.
        var tocCacheHit = false
        if let accountId = AppContainer.production().accountsManager.currentAccountId,
           let cached = ReadiumPDFTOCCache.read(bookIdentifier: book.identifier, account: accountId) {
            coordinator?.storeReadiumPDFTableOfContents(cached.toc, pageCount: cached.pageCount, forBookId: book.identifier)
            tocCacheHit = true
        }

        coordinator?.push(.pdf(BookRoute(id: book.identifier)))
        Log.info(#file, "[PERF] [LCP-PDF] T1 route pushed (+\(Self.ms(since: openStartedAt))ms, tocDiskHit=\(tocCacheHit))")
        onFinish?()

        let libraryOpenStartedAt = Date()
        r3Owner.libraryService.openBook(book, sender: presenter) { [weak self] result in
            let libraryOpenElapsedMs = Self.ms(since: libraryOpenStartedAt)
            switch result {
            case .success(let publication):
                Task { @MainActor in
                    guard let self else { return }
                    // Stale-completion guard: if the user backed out (or
                    // started a fresh open) while libraryService.openBook
                    // was decrypting in the background, the generation
                    // we started under no longer matches. Drop the
                    // publication on the floor instead of storing it.
                    let currentGeneration = self.openGenerationByBookId[book.identifier, default: 0]
                    guard currentGeneration == generation else {
                        Log.info(#file, "[PERF] [LCP-PDF] stale openBook completion ignored for \(book.identifier) (gen=\(generation) current=\(currentGeneration))")
                        return
                    }
                    self.openInFlightBookIds.remove(book.identifier)
                    guard let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator else {
                        Log.error(#file, "📄 [Readium PDF] No NavigationCoordinator when publication landed")
                        return
                    }
                    Log.info(#file, "[PERF] [LCP-PDF] T2 publication opened (+\(Self.ms(since: openStartedAt))ms total, libraryService.openBook=\(libraryOpenElapsedMs)ms)")
                    LCPPDFOpenProgress.shared.setPhase(.loadingFirstPage)
                    // Reuse the cached TOC snapshot if we already loaded
                    // it on a previous open — saves the second
                    // publication.tableOfContents() + publication.positions()
                    // round-trip (each triggers AES decrypt of the PDF
                    // cross-ref table, which is what dominates re-open
                    // time on large Marketplace containers).
                    let hasCachedTOC = coordinator.resolveReadiumPDFTableOfContents(for: BookRoute(id: book.identifier)) != nil

                    // Store the publication FIRST so the navigator can
                    // start rendering page 1 immediately. TOC + page
                    // count load in the background — side panels show
                    // empty until that lands, then re-render. Without
                    // this split the user waits for positions() to walk
                    // the entire decrypted PDF (the hundreds of
                    // "Successfully decrypted 2064 -> 2048" log lines)
                    // BEFORE seeing page 1.
                    let metadata = TPPPDFDocumentMetadata(with: book)
                    coordinator.storeReadiumPDF(publication: publication, metadata: metadata, forBookId: book.identifier)

                    if !hasCachedTOC {
                        // Background-load TOC + positions. Uses a low-
                        // priority Task so it yields to navigator work.
                        // Persist the snapshot to disk so a cold-app
                        // re-open of the same book skips this entirely.
                        let tocLoadStartedAt = Date()
                        Task.detached(priority: .utility) {
                            let toc = await Self.loadTableOfContents(for: publication)
                            let tocElapsedMs = Self.ms(since: tocLoadStartedAt)
                            let positionsStartedAt = Date()
                            let pageCount = await Self.loadPageCount(for: publication)
                            let positionsElapsedMs = Self.ms(since: positionsStartedAt)
                            let bookId = book.identifier
                            await MainActor.run {
                                Log.info(#file, "[PERF] [LCP-PDF] T3 TOC+positions loaded (+\(Self.ms(since: openStartedAt))ms total, toc=\(tocElapsedMs)ms, positions=\(positionsElapsedMs)ms, entries=\(toc.count), pages=\(pageCount))")
                                AppContainer.production().navigationCoordinatorHub.coordinator?
                                    .storeReadiumPDFTableOfContents(toc, pageCount: pageCount, forBookId: bookId)
                                if let accountId = AppContainer.production().accountsManager.currentAccountId {
                                    ReadiumPDFTOCCache.write(toc: toc, pageCount: pageCount, bookIdentifier: bookId, account: accountId)
                                }
                            }
                        }
                    }
                }
            case .failure(let error):
                Task { @MainActor in
                    guard let self else { return }
                    self.openInFlightBookIds.remove(book.identifier)
                    self.presentOpenFailureAlert(for: error, book: book, isRetry: false)
                    // Pop the route on failure — the user shouldn't be left
                    // sitting on a loading spinner.
                    coordinator?.removeReadiumPDF(forBookId: book.identifier)
                    if let path = coordinator?.path, path.count > 0 {
                        coordinator?.path.removeLast()
                    }
                }
            }
        }
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
}
