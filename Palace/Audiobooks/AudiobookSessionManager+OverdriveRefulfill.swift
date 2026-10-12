//
//  AudiobookSessionManager+OverdriveRefulfill.swift
//  Palace
//
//  The OverDrive expired-link recovery (PP-4800, PP-4967): re-fulfil through
//  the download centre, re-open from the fresh manifest, or tell the patron
//  the link could not be renewed. Kept out of the hub so it does not count
//  against AudiobookSessionManager's line-count ceiling.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry
import PalaceLogging

extension AudiobookSessionManager {

    /// PP-4967: dismisses the player and tells the patron the expired link could
    /// not be replaced, and what to do about it.
    func dismissAndPresentOverdriveLinkRenewalFailed() async {
        await stopPlayback(dismissPhoneUI: true, persistFinalPosition: false)
        await MainActor.run {
            let alert = TPPAlertUtils.alert(
                title: Strings.OverdriveLinkRenewal.title,
                message: Strings.OverdriveLinkRenewal.message
            )
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
        }
    }

#if FEATURE_OVERDRIVE
    /// PP-4800: recovers an OverDrive audiobook whose on-disk manifest holds
    /// expired signed URLs (surfaced as AVPlayer -1008). The audiobook loader
    /// CANNOT re-fulfill OverDrive — its `forceRefulfill` routes to
    /// `OpenAccessAdapter`, whose generic bearer-token second leg hits OverDrive's
    /// `downloadlink` WITHOUT the `x-overdrive-scope`/`x-overdrive-patron-
    /// authorization` headers → 401 (device-confirmed). Only the download path
    /// (`OverdriveDownloadHandler.processOverdriveDownload`) runs the 302 header
    /// dance that authorizes fresh URLs. The download center refuses a start for a
    /// `.downloadSuccessful` book (`DownloadStartCoordinator`: "Ignoring
    /// nonsensical download request"), so reset to `.downloadNeeded` first, trigger
    /// the fresh fulfillment, await the registry returning to `.downloadSuccessful`
    /// (fresh manifest on disk, bounded), then re-open from the fresh LOCAL file.
    /// Bounded to one attempt/book/session by the caller.
    func recoverExpiredOverdriveByRefulfilling(_ book: TPPBook) async {
        let id = book.identifier
        // The download center rejects a start for an already-downloaded book, so
        // mark it needs-download before triggering the fresh OverDrive fulfillment.
        bookRegistry.setState(.downloadNeeded, for: id)
        overdriveRefulfillStarter(book)
        let landed = await awaitDownloadSuccessful(id, timeout: 90)
        // Out of flight on every path, before the re-open: failures until here
        // came from the old player and were suppressed; the re-open's own
        // failure is the answer and must reach the reducer (PP-4967).
        noteOverdriveRefulfillFinished(for: id)
        // A newer open (user tapped a different book) supersedes this recovery.
        guard currentBook?.identifier == id else { return }
        if landed {
            Log.info(#file, "OverDrive re-fulfillment landed a fresh manifest — re-opening '\(book.title)'")
            // isRecoveryReopen bypasses openAudiobook's `.alreadyLoading` guard —
            // `state` is still `.loading` from the anti-flash handler. forceRefulfill
            // stays false so the re-open reads the freshly-refreshed LOCAL manifest.
            _ = await openAudiobook(book, startPlaying: true, forceRefulfill: false, isRecoveryReopen: true)
        } else {
            Log.info(#file, "OverDrive re-fulfillment did not complete — surfacing the link-renewal message for '\(book.title)'")
            await dismissAndPresentOverdriveLinkRenewalFailed()
        }
    }

    /// Polls the registry (on the main actor) for `id` reaching a terminal
    /// download state after a re-fulfillment: `.downloadSuccessful`/`.used` → true
    /// (fresh manifest on disk); `.downloadFailed`/`.unregistered`/`.unsupported`
    /// → false; otherwise keep waiting up to `timeout` seconds. Polling (vs a
    /// Combine subscription racing a timeout) keeps the whole recovery on the main
    /// actor with no continuation/`Sendable` hazard, and can't miss an event since
    /// each tick reads the current state. Bails early if a newer open supersedes.
    private func awaitDownloadSuccessful(_ id: String, timeout: TimeInterval) async -> Bool {
        let pollNanos: UInt64 = 250_000_000
        var waited: TimeInterval = 0
        while waited < timeout {
            try? await Task.sleep(nanoseconds: pollNanos)
            waited += 0.25
            guard currentBook?.identifier == id else { return false }
            if let outcome = Self.overdriveRefulfillOutcome(for: bookRegistry.state(for: id)) {
                return outcome
            }
        }
        return false
    }

    /// Pure classification of a registry state during the OverDrive re-fulfill poll:
    /// `.some(true)` = a fresh manifest landed (stop polling, re-open); `.some(false)`
    /// = a terminal failure (stop, surface unavailable); `nil` = not yet terminal
    /// (keep polling).
    static func overdriveRefulfillOutcome(for state: TPPBookState) -> Bool? {
        switch state {
        case .downloadSuccessful, .used:
            return true
        case .downloadFailed, .unregistered, .unsupported:
            return false
        default:
            return nil
        }
    }
#endif
}
