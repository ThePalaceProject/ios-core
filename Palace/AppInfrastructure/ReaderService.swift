import UIKit
import ReadiumShared
#if LCP
import ReadiumLCP
#endif

final class ReaderService {
    static let shared = ReaderService()
    private init() {}

    private lazy var r3Owner: TPPR3Owner = TPPR3Owner()

    #if DEBUG
    /// Set to a non-nil `LCPError` before opening a book to simulate an LCP
    /// failure on the first open attempt. Consumed after a single use so the
    /// retry (or subsequent opens) behave normally.
    ///
    /// Usage in tests or the simulator:
    /// ```swift
    /// ReaderService.simulatedLCPError = .missingPassphrase
    /// // now tap/call openEPUB — the retry path fires, re-fetches the license,
    /// // and opens the book transparently (or shows the error after one retry)
    /// ```
    static var simulatedLCPError: LCPError? = nil
    #endif

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
        #if DEBUG
        if !isRetry, let simulatedError = Self.simulatedLCPError {
            Self.simulatedLCPError = nil
            Log.info(#file, "DEBUG: simulating LCP open failure with \(simulatedError)")
            presentOpenFailureAlert(
                for: .openFailed(simulatedError),
                book: book,
                isRetry: false
            )
            return
        }
        #endif

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

    /// Presents the appropriate alert for a failed book open.
    ///
    /// Priority order:
    /// 1. If it's a definitive DRM status error (expired/returned/revoked/cancelled) → "Your Loan Has Expired"
    /// 2. If it's a recoverable LCP error (missing passphrase, network, CRL) and this is the first
    ///    attempt → silently re-fetch a fresh license from the CM and retry once.
    /// 3. Fallback → generic "Content Protection Error" (logged to Crashlytics).
    @MainActor
    private func presentOpenFailureAlert(for error: LibraryServiceError, book: TPPBook, isRetry: Bool = false) {
        let inner: Error?
        if case .openFailed(let e) = error { inner = e } else { inner = nil }

        if let message = Self.expiredLoanMessage(for: inner) {
            let alert = UIAlertController(
                title: Strings.ExpiredLoan.title,
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: Strings.Announcments.ok, style: .default) { _ in
                MyBooksDownloadCenter.shared.returnBook(withIdentifier: book.identifier)
            })
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
            return
        }

        #if LCP
        if !isRetry, let lcpError = inner as? LCPError, Self.isRecoverableLCPError(lcpError) {
            Log.info(#file, "LCP open failed with recoverable error (\(lcpError)) — attempting license refresh for \(book.title)")
            attemptLicenseRefreshAndReopen(book: book, originalError: error)
            return
        }
        #endif

        TPPErrorLogger.logError(
            withCode: .lcpPassphraseRetrievalFail,
            summary: "Content Protection Error shown to user",
            metadata: [
                "bookTitle": book.title,
                "bookIdentifier": book.identifier,
                "error": (inner ?? error).localizedDescription,
                "wasRetried": isRetry
            ]
        )
        let alert = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
    }

    #if LCP
    /// Returns `true` for LCP errors that may be resolved by fetching a fresh license from the CM.
    /// Definitive status errors (expired, returned, revoked, cancelled) are NOT recoverable.
    static func isRecoverableLCPError(_ error: LCPError) -> Bool {
        switch error {
        case .missingPassphrase, .network, .crlFetching, .licenseIntegrity:
            return true
        default:
            return false
        }
    }

    /// Fetches a fresh LCP license document from the CM fulfill URL, injects it into the
    /// local EPUB, and retries opening once. On any failure, falls through to the generic
    /// "Content Protection Error" alert.
    @MainActor
    private func attemptLicenseRefreshAndReopen(book: TPPBook, originalError: LibraryServiceError) {
        guard let fulfillURL = book.defaultAcquisition?.hrefURL else {
            Log.error(#file, "LCP license refresh: no fulfill URL available for \(book.title)")
            presentOpenFailureAlert(for: originalError, book: book, isRetry: true)
            return
        }

        guard let epubURL = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier) else {
            Log.error(#file, "LCP license refresh: no local EPUB file found for \(book.title)")
            presentOpenFailureAlert(for: originalError, book: book, isRetry: true)
            return
        }

        TPPNetworkExecutor.shared.GET(fulfillURL) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let data, _):
                let tempLCPL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lcpl_refresh_\(UUID().uuidString).lcpl")

                do {
                    try data.write(to: tempLCPL, options: .atomic)
                    Log.info(#file, "LCP license refresh: downloaded fresh license (\(data.count) bytes)")
                } catch {
                    Log.error(#file, "LCP license refresh: failed to write temp LCPL — \(error)")
                    Task { @MainActor in self.presentOpenFailureAlert(for: originalError, book: book, isRetry: true) }
                    return
                }

                Task { @MainActor in
                    do {
                        try await TPPLicensesService().injectLicense(
                            lcpl: tempLCPL,
                            to: epubURL,
                            at: "META-INF/license.lcpl"
                        )
                        try? FileManager.default.removeItem(at: tempLCPL)
                        Log.info(#file, "LCP license refresh: injected fresh license into EPUB — retrying open")
                        self.openEPUBInternal(book, isRetry: true)
                    } catch {
                        try? FileManager.default.removeItem(at: tempLCPL)
                        Log.error(#file, "LCP license refresh: failed to inject license — \(error)")
                        self.presentOpenFailureAlert(for: originalError, book: book, isRetry: true)
                    }
                }

            case .failure(let error, _):
                Log.error(#file, "LCP license refresh: CM request failed — \(error.localizedDescription)")
                Task { @MainActor in self.presentOpenFailureAlert(for: originalError, book: book, isRetry: true) }
            }
        }
    }
    #endif

    /// Returns a user-facing message if `error` represents an expired or revoked DRM license,
    /// `nil` for any other error type.
    private static func expiredLoanMessage(for error: Error?) -> String? {
        guard let error else { return nil }

        #if LCP
        if let lcpError = error as? LCPError,
           case .licenseStatus(let statusError) = lcpError {
            switch statusError {
            case .expired(_, let end):
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                return String(format: Strings.ExpiredLoan.messageWithDate, formatter.string(from: end))
            case .returned, .revoked, .cancelled:
                return Strings.ExpiredLoan.message
            }
        }
        #endif

        #if FEATURE_DRM_CONNECTOR
        if error is AdobeDRMError {
            return Strings.ExpiredLoan.message
        }
        #endif

        return nil
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
