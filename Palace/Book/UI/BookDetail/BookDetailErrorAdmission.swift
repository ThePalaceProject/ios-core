//
//  BookDetailErrorAdmission.swift
//  Palace
//
//  Decides whether a published download or borrow error belongs to what the
//  book-detail sheet is currently showing. Pure, so the admission rules are
//  testable without a view model, a download centre or a registry.
//

import Foundation
import PalaceBookModel

enum BookDetailErrorAdmission {

    /// True when an error of `kind` is about the acquisition the sheet is
    /// rendering, and so should both alert and resync it.
    ///
    /// `.borrow` admits `.holding` and `.reserve` as well as `.get` and
    /// `.unregistered`: the PP-4178 Loan→Hold race registers the hold and only
    /// then throws, so by the time the error arrives `BorrowReducer` has
    /// cleared `.get` and moved the state to `.holding`. Place Hold is the same
    /// shape with `.reserve`. `BookCellModel` admits `.unregistered` and
    /// `.holding` for the same reason.
    static func admits(
        kind: DownloadErrorInfo.ErrorKind,
        bookState: TPPBookState,
        processingButtons: Set<BookButtonType>
    ) -> Bool {
        switch kind {
        case .borrow:
            return !processingButtons.isDisjoint(with: [.get, .reserve])
                || bookState == .unregistered || bookState == .holding
        case .download:
            return !processingButtons.isDisjoint(with: [.download, .retry])
                || bookState == .downloading || bookState == .downloadFailed
                || bookState == .downloadNeeded
        case .general:
            return true
        }
    }
}
