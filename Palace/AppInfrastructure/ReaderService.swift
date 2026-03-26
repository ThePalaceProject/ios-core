import UIKit
import ReadiumShared
#if LCP
import ReadiumLCP
#endif

final class ReaderService {
    static let shared = ReaderService()
    private init() {}

    private lazy var r3Owner: TPPR3Owner = TPPR3Owner()

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
                self.presentOpenFailureAlert(for: error, book: book)
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
    /// If the underlying error is a DRM license status error (expired, returned, revoked, or
    /// cancelled), we show a friendly "Your Loan Has Expired" message and clean up the local
    /// copy via `returnBook`. For all other failures we fall back to the generic
    /// "Content Protection Error" alert.
    @MainActor
    private func presentOpenFailureAlert(for error: LibraryServiceError, book: TPPBook) {
        // Unwrap the inner error from LibraryServiceError.openFailed
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
        } else {
            let alert = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
        }
    }

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
