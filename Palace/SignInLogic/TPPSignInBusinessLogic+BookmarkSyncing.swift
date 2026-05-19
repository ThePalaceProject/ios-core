//
//  TPPSignInBusinessLogic+BookmarkSyncing.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/4/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceLogging

extension TPPSignInBusinessLogic {
    @objc func shouldShowSyncButton() -> Bool {
        // Phase 2 Bucket B (swarm_81b5099e follow-up): state-machine-aware
        // read. Returns false while details are still loading instead of
        // racing a partially-populated `details?`. Bookmark sync is a
        // best-effort silent-failure path per the ADR — denying the sync
        // button until details are confirmed is the right default (the
        // button reappears on the next render after .detailsLoaded fires).
        guard let libraryDetails = loadedAccountDetails else {
            Log.debug(#file, "🔖 shouldShowSyncButton: NO - loadedAccountDetails is nil (state-machine not yet .detailsLoaded)")
            return false
        }

        let supportsSync = libraryDetails.supportsSimplyESync
        // Use TPPAnnotations.annotationsURL which computes the URL from mainFeedURL
        // instead of getLicenseURL(.annotations) which is never populated
        let hasAnnotationsURL = TPPAnnotations.annotationsURL != nil
        let hasCredentials = userAccount.hasCredentials()
        let isCurrentAccount = libraryAccountID == libraryAccountsProvider.currentAccountId

        Log.debug(#file, """
      🔖 shouldShowSyncButton check for '\(libraryAccount?.name ?? "unknown")':
         supportsSimplyESync: \(supportsSync)
         hasAnnotationsURL: \(hasAnnotationsURL) (URL: \(TPPAnnotations.annotationsURL?.absoluteString ?? "nil"))
         hasCredentials: \(hasCredentials)
         isCurrentAccount: \(isCurrentAccount) (libraryAccountID: \(libraryAccountID ?? "nil"), currentAccountId: \(libraryAccountsProvider.currentAccountId ?? "nil"))
      """)

        let result = supportsSync && hasAnnotationsURL && hasCredentials && isCurrentAccount
        Log.debug(#file, "🔖 shouldShowSyncButton result: \(result)")

        return result
    }
}
