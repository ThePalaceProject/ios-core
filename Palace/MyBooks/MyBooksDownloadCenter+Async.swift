//
//  MyBooksDownloadCenter+Async.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//
//  Forwarders to `BorrowOperation`, which implements the borrow lifecycle.
//

import Foundation
import PalaceCatalog
import PalaceBookModel

extension MyBooksDownloadCenter {

    // MARK: - Static Forwarders

    /// Clears all borrow re-auth tracking state. Called on account
    /// switch via AccountsManager so stale circuit-breaker state from
    /// the previous account can't suppress legitimate re-auth attempts.
    static func clearAllBorrowReauthState() {
        BorrowOperation.clearAllBorrowReauthState()
    }

    /// Pure mapping helper exposed for integration-test callers.
    /// See `BorrowOperation.borrowResponseState(for:preBorrowBook:)` for
    /// the canonical implementation, PP-4178 rationale, and Place Hold
    /// disambiguation.
    static func borrowResponseState(
        for postBorrowBook: TPPBook,
        preBorrowBook: TPPBook? = nil
    ) -> (state: TPPBookState, error: PalaceError?) {
        BorrowOperation.borrowResponseState(for: postBorrowBook, preBorrowBook: preBorrowBook)
    }

    /// Pure error-message builder exposed for TPPAlertUtilsTests.
    /// See `BorrowOperation.buildBorrowErrorMessage(...)` for the
    /// canonical implementation.
    static func buildBorrowErrorMessage(
        for bookTitle: String,
        error: PalaceError,
        problemDocument: TPPProblemDocument?
    ) -> String {
        BorrowOperation.buildBorrowErrorMessage(
            for: bookTitle,
            error: error,
            problemDocument: problemDocument
        )
    }

    // MARK: - Instance Forwarder

    /// Borrows a book asynchronously. Forwards to `BorrowOperation`.
    /// The `DownloadStartCoordinatorDelegate.borrowAsync` hop calls
    /// this method; preserving the signature here keeps that delegate
    /// conformance intact.
    func borrowAsync(
        _ book: TPPBook,
        attemptDownload: Bool = false
    ) async throws -> TPPBook {
        try await borrowOperation.borrowAsync(book, attemptDownload: attemptDownload)
    }
}
