//
//  BookDetailViewModel+Return.swift
//  Palace
//
//  Starts a patron's return from the book detail sheet. The completion is
//  reduced through `BorrowReducer` in `returnDidFinish()`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel

extension BookDetailViewModel {
    // `completion` is `@Sendable` so the closure handed to
    // `downloadCenter.returnBook` (which threads it through BookReturnService's
    // async return state machine) carries no non-Sendable capture. The sole
    // caller passes an `@MainActor`-isolated closure, so this is additive.
    func didSelectReturn(for book: TPPBook, completion: (@Sendable () -> Void)?) {
        processingButtons.insert(.returning)
        downloadCenter.returnBook(withIdentifier: book.identifier) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.returnDidFinish()
                completion?()
            }
        }
    }
}
