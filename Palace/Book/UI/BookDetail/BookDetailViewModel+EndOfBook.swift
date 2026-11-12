//
//  BookDetailViewModel+EndOfBook.swift
//  Palace
//
//  The prompt shown when an audiobook finishes: offer to return the loan,
//  and note the finished book for the rating prompt.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceCatalog

extension BookDetailViewModel {
    static func presentEndOfBookAlert(for book: TPPBook,
                                      downloadCenter: MyBooksDownloadCenter,
                                      navigationHub: NavigationCoordinatorHub,
                                      bookCompletion: BookCompletionNoting) {
        let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
            forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
            allowedRelations: TPPOPDSAcquisitionRelationSetBorrow | TPPOPDSAcquisitionRelationSetGeneric,
            acquisitions: book.acquisitions
        )

        if paths.count > 0 {
            let alert = TPPReturnPromptHelper.audiobookPrompt(
                completion: endOfBookChoiceHandler(for: book,
                                                   downloadCenter: downloadCenter,
                                                   navigationHub: navigationHub,
                                                   bookCompletion: bookCompletion))
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
        } else {
            Task { @MainActor in bookCompletion.noteBookCompleted() }
        }
    }

    /// What the end-of-book prompt does with the patron's answer.
    static func endOfBookChoiceHandler(for book: TPPBook,
                                       downloadCenter: MyBooksDownloadCenter,
                                       navigationHub: NavigationCoordinatorHub,
                                       bookCompletion: BookCompletionNoting) -> @MainActor @Sendable (Bool) -> Void {
        { returnWasChosen in
            if returnWasChosen {
                navigationHub.coordinator?.pop()
                downloadCenter.returnBook(withIdentifier: book.identifier)
            }
            Task { @MainActor in bookCompletion.noteBookCompleted() }
        }
    }
}
