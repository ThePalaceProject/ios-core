//
//  BookAvailabilityFormatter.swift
//  Palace
//
//  Extracted from BookDetailViewModel.swift
//  Formats availability information for display:
//  hold position, copy counts, date formatting, availability windows.
//

import Foundation
import PalaceAudiobookToolkit

/// Provides audiobook location sync UI helpers formerly located in BookDetailViewModel.
/// Also hosts the end-of-book alert and timer-based polling logic.
@MainActor
final class BookAvailabilityFormatter {

    // MARK: - Audiobook Location Sync

    static func chooseLocalLocation(
        localPosition: TrackPosition?,
        remotePosition: TrackPosition?,
        serverUpdateDelay: TimeInterval,
        operation: @escaping (TrackPosition) -> Void
    ) {
        let remoteLocationIsNewer: Bool

        if let localPosition = localPosition, let remotePosition = remotePosition {
            remoteLocationIsNewer = String.isDate(remotePosition.lastSavedTimeStamp, moreRecentThan: localPosition.lastSavedTimeStamp, with: serverUpdateDelay)
        } else {
            remoteLocationIsNewer = localPosition == nil && remotePosition != nil
        }

        if let remotePosition = remotePosition,
           remotePosition.description != localPosition?.description,
           remoteLocationIsNewer {
            requestSyncWithCompletion { shouldSync in
                let location = shouldSync ? remotePosition : (localPosition ?? remotePosition)
                operation(location)
            }
        } else if let localPosition = localPosition {
            operation(localPosition)
        } else if let remotePosition = remotePosition {
            operation(remotePosition)
        }
    }

    static func requestSyncWithCompletion(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let title = LocalizedStrings.syncListeningPositionAlertTitle
            let message = LocalizedStrings.syncListeningPositionAlertBody
            let moveTitle = LocalizedStrings.move
            let stayTitle = LocalizedStrings.stay

            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)

            let moveAction = UIAlertAction(title: moveTitle, style: .default) { _ in
                completion(true)
            }

            let stayAction = UIAlertAction(title: stayTitle, style: .cancel) { _ in
                completion(false)
            }

            alertController.addAction(moveAction)
            alertController.addAction(stayAction)

            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alertController, viewController: nil, animated: true, completion: nil)
        }
    }

    // MARK: - End of Book

    static func presentEndOfBookAlert(for book: TPPBook) {
        let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
            forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
            allowedRelations: [.borrow, .generic],
            acquisitions: book.acquisitions
        )

        if paths.count > 0 {
            let alert = TPPReturnPromptHelper.audiobookPrompt { returnWasChosen in
                if returnWasChosen {
                    NavigationCoordinatorHub.shared.coordinator?.pop()
                    MyBooksDownloadCenter.shared.returnBook(withIdentifier: book.identifier)
                }
                TPPAppStoreReviewPrompt.presentIfAvailable()
            }
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
        } else {
            TPPAppStoreReviewPrompt.presentIfAvailable()
        }
    }
}
