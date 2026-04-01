import UIKit
import Combine
import ReadiumShared
#if LCP
import ReadiumLCP
#endif

final class ReaderService {
    static let shared = ReaderService()
    private init() {}

    private lazy var r3Owner: TPPR3Owner = TPPR3Owner()

    /// Stores Combine subscriptions observing re-download completion per book.
    /// Keyed by book identifier so concurrent open attempts don't clobber each other.
    private var redownloadObservers: [String: AnyCancellable] = [:]
    private var redownloadTimeouts: [String: Task<Void, Never>] = [:]

    private func topPresenter() -> UIViewController {
        guard let root = UIApplication.shared.mainKeyWindow?.rootViewController else {
            return UIViewController()
        }
        var base: UIViewController = root
        while let presented = base.presentedViewController { base = presented }
        return base
    }

    @MainActor
    func openEPUB(_ book: TPPBook) {
        openEPUBInternal(book, isRetry: false)
    }

    @MainActor
    private func openEPUBInternal(_ book: TPPBook, isRetry: Bool) {
        r3Owner.libraryService.openBook(book, sender: topPresenter()) { result in
            switch result {
            case .success(let publication):
                if let coordinator = NavigationCoordinatorHub.shared.coordinator {
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
        r3Owner.libraryService.openSample(book, sampleURL: url, sender: topPresenter()) { result in
            switch result {
            case .success(let publication):
                if let coordinator = NavigationCoordinatorHub.shared.coordinator {
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
        MyBooksDownloadCenter.shared.deleteLocalContent(for: book.identifier)
        TPPBookRegistry.shared.setState(.downloadNeeded, for: book.identifier)

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

        redownloadObservers[book.identifier] = TPPBookRegistry.shared.bookStatePublisher
            .filter { identifier, _ in identifier == book.identifier }
            .sink { [weak self] _, state in
                guard let self else { return }
                switch state {
                case .downloadSuccessful:
                    self.cancelRedownload(for: book.identifier)
                    Log.info(#file, "Re-download succeeded — retrying open for '\(book.title)'")
                    self.openEPUBInternal(book, isRetry: true)
                case .downloadFailed:
                    Log.error(#file, "Re-download failed for '\(book.title)' — showing Content Protection Error")
                    showFallback()
                default:
                    break
                }
            }

        MyBooksDownloadCenter.shared.startDownload(for: book)
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
    func makeEPUBViewController(for publication: Publication, book: TPPBook, forSample: Bool) async throws -> UIViewController {
        let bookRegistry = TPPBookRegistry.shared

        // Sync reading position with server before opening (shows "Stay or Move"
        // dialog when the server has a different position from another device).
        // Samples don't need sync since they have no persisted position.
        if !forSample {
            let synchronizer = TPPLastReadPositionSynchronizer(bookRegistry: bookRegistry)
            let drmDeviceID = TPPUserAccount.sharedAccount().deviceID
            await synchronizer.sync(for: publication, book: book, drmDeviceID: drmDeviceID)
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
