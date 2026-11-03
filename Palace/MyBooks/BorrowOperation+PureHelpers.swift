//
//  BorrowOperation+PureHelpers.swift
//  Palace
//
//  Borrow helpers that read no operation state.
//

import Foundation
import PalaceBookModel
import PalaceCatalog

extension BorrowOperation {

    /// Races an async operation against a deadline; the loser is cancelled.
    /// Expiry throws `PalaceError.network(.timeout)` so the borrow-error alert
    /// with Retry appears instead of the half-sheet spinning forever.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PalaceError.network(.timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw PalaceError.network(.timeout)
            }
            return first
        }
    }

    /// Maps a borrow/place-hold response to a registry state and optional error.
    /// Delegates to `BorrowReducerCore.responseState`.
    static func borrowResponseState(
        for postBorrowBook: TPPBook,
        preBorrowBook: TPPBook? = nil
    ) -> (state: TPPBookState, error: PalaceError?) {
        BorrowReducerCore.responseState(for: postBorrowBook, preBorrowBook: preBorrowBook)
    }

    /// Builds a user-friendly borrow error message that always uses
    /// the localized "Borrowing [title] could not be completed." base
    /// instead of raw `PalaceError.localizedDescription` (which can
    /// contain technical strings that confuse users).
    static func buildBorrowErrorMessage(
        for bookTitle: String,
        error: PalaceError,
        problemDocument: TPPProblemDocument?
    ) -> String {
        let baseMessage = String(format: Strings.MyDownloadCenter.borrowFailedMessage, bookTitle)

        if let doc = problemDocument, let detail = doc.detail, !detail.isEmpty {
            return baseMessage + "\n\n" + detail
        }

        if let recovery = error.recoverySuggestion {
            return baseMessage + "\n\n" + recovery
        }

        return baseMessage
    }
}
