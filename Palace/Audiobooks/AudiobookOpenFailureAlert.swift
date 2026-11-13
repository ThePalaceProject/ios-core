//
//  AudiobookOpenFailureAlert.swift
//  Palace
//
//  The "could not open this audiobook" alert shown after a loader failure, with
//  its Retry (PP-3707) and the non-fatal report filed before it is shown.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import UIKit
import PalaceBookModel
import PalaceBookRegistry
import PalaceLogging

/// Reports an audiobook open failure and offers the patron a bounded Retry.
///
/// The report keeps a fixed domain and code so its Crashlytics issue groups the
/// same way across releases; the cause travels in `failureMetadata` (PP-5242).
@MainActor
struct AudiobookOpenFailureAlert {
    static let errorDomain = "AudiobookOpenError"

    private let errorLogger: ErrorLogging
    private let retryTracker: UserRetryTracker
    private let present: @MainActor (UIAlertController) -> Void
    private let reopen: @MainActor (TPPBook) -> Void

    init(errorLogger: ErrorLogging,
         retryTracker: UserRetryTracker,
         present: @escaping @MainActor (UIAlertController) -> Void,
         reopen: @escaping @MainActor (TPPBook) -> Void) {
        self.errorLogger = errorLogger
        self.retryTracker = retryTracker
        self.present = present
        self.reopen = reopen
    }

    /// Production wiring. Retry reopens through `BookOpenRouter` with the
    /// caller's registry, the same route a patron's Listen tap takes.
    static func production(bookRegistry: TPPBookRegistryProvider) -> AudiobookOpenFailureAlert {
        AudiobookOpenFailureAlert(
            errorLogger: DefaultErrorLogger(),
            retryTracker: .shared,
            present: { alert in
                TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
            },
            reopen: { book in BookOpenRouter.open(book, bookRegistry: bookRegistry) }
        )
    }

    /// The session manager's production `showOpenFailureAlert` dependency.
    static func presenter(bookRegistry: TPPBookRegistryProvider) -> @MainActor (TPPBook, [String: Any]) -> Void {
        { book, failureMetadata in
            production(bookRegistry: bookRegistry).show(book: book, failureMetadata: failureMetadata)
        }
    }

    /// Retry budget key, shared with every earlier open failure of this book.
    static func retryOperationId(for book: TPPBook) -> String {
        "audiobook-open-\(book.identifier)"
    }

    func show(book: TPPBook, failureMetadata: [String: Any] = [:]) {
        Log.warn(#file, "⚠️ [ERROR ALERT] Showing 'An error was encountered while trying to open this book' alert to user")

        let error = NSError(
            domain: Self.errorDomain,
            code: TPPErrorCode.audiobookCorrupted.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to open audiobook",
                "error_type": "audiobook_open_failure"
            ]
        )
        errorLogger.logError(
            error,
            summary: "Audiobook failed to open - showing try again error",
            metadata: failureMetadata.merging(["user_message": Strings.Error.tryAgain]) { _, fixed in fixed }
        )

        let operationId = Self.retryOperationId(for: book)
        guard retryTracker.canRetry(operationId: operationId) else {
            present(TPPAlertUtils.alert(title: Strings.Error.openFailedError, message: Strings.MyDownloadCenter.tryAgainLater))
            return
        }

        let alert = UIAlertController(
            title: Strings.Error.openFailedError,
            message: Strings.Error.tryAgain,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: Strings.MyDownloadCenter.retry, style: .default) { [retryTracker, reopen] _ in
            retryTracker.recordRetry(operationId: operationId)
            reopen(book)
        })
        alert.addAction(UIAlertAction(title: Strings.Generic.cancel, style: .cancel))
        present(alert)
    }
}
