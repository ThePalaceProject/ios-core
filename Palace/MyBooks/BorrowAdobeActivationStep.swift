//
//  BorrowAdobeActivationStep.swift
//  Palace
//
//  The Adobe device-activation step of a borrow, extracted out of
//  `BorrowOperation` so the hub does not grow while the decomposition campaign
//  runs (Wave 0 ratchet). One cohesive concern: activate the device for an
//  Adobe-DRM title, and keep the UI honest while that happens.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry
import PalaceLogging

#if FEATURE_DRM_CONNECTOR

/// Runs Adobe device activation for a borrow, holding the processing spinner
/// for the duration.
///
/// The spinner is raised BEFORE activation rather than after. Activation can
/// wait for a licensor that sign-in is still writing (PP-5025), and
/// `BookCellModel.didSelectDownload` sets no `isLoading` of its own — so
/// without this the catalog's Get button sits unchanged and tappable for the
/// whole wait, while `DownloadStartCoordinator`'s duplicate-tap guard keys on
/// download info that does not exist yet. It is cleared again if activation
/// throws, so a failure never strands the spinner.
///
/// The licensor grace period is passed explicitly here and nowhere else.
/// Borrow is the path where the race was measured, and the only activation
/// path that can afford to wait: the read path (`BookDetailViewModel`) and the
/// fulfillment dispatcher (`RightsManagementDispatcher`) both hold
/// user-visible state and keep the fail-fast default.
enum BorrowAdobeActivationStep {

    /// - Parameters:
    ///   - setProcessing: raises/clears the book's processing spinner.
    ///   - activate: performs device activation with the grace period it is
    ///     handed. Injected rather than taking an `AdobeDRMService` so this
    ///     step's three responsibilities — the budget it opts into, the spinner
    ///     order, and the clear-on-throw — are all pinnable by tests. The
    ///     concrete service reaches `AppContainer.production()` internally,
    ///     which is not a seam a test can stand behind.
    /// - Throws: whatever `activate` throws, after clearing the processing
    ///   state.
    static func run(setProcessing: @escaping @MainActor (Bool) -> Void,
                    activate: (TimeInterval) async throws -> Void) async throws {
        await MainActor.run { setProcessing(true) }
        do {
            try await activate(AdobeDRMService.defaultLicensorGracePeriod)
        } catch {
            await MainActor.run { setProcessing(false) }
            throw error
        }
    }
}

#endif
