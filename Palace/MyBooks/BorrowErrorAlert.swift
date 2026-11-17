//
//  BorrowErrorAlert.swift
//  Palace
//
//  The borrow-failed alert, lifted out of MyBooksDownloadCenter's init so the
//  presentation and its signature live next to each other and neither hub
//  carries the closure body.
//

import Foundation
import PalaceCatalog
import PalaceBookModel

/// Signature of `BorrowOperation`'s alert-presentation seam.
typealias BorrowErrorAlertPresenting = @MainActor (
    _ title: String,
    _ message: String,
    _ originalError: NSError?,
    _ problemDocument: TPPProblemDocument?,
    _ book: TPPBook,
    _ retryAction: (() -> Void)?
) -> Void

enum BorrowErrorAlert {

    /// Presents the borrow-failed alert. `alertWithDetails` is what carries the
    /// "View Error Details" report (PP-3439); the SwiftUI `Alert` the half-sheet
    /// builds takes two buttons and a retryable borrow failure uses both, so the
    /// published path cannot offer it. See `DownloadErrorInfo.presentsAlert`.
    @MainActor
    static func present(
        title: String,
        message: String,
        originalError: NSError?,
        problemDocument: TPPProblemDocument?,
        book: TPPBook,
        retryAction: (() -> Void)?
    ) {
        let alert = TPPAlertUtils.alertWithDetails(
            title: title,
            message: message,
            error: originalError,
            problemDocument: problemDocument,
            bookIdentifier: book.identifier,
            bookTitle: book.title,
            retryAction: retryAction
        )
        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: alert,
            viewController: nil,
            animated: true,
            completion: nil
        )
    }
}
