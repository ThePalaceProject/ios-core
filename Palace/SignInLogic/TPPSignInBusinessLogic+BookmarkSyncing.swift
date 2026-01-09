//
//  TPPSignInBusinessLogic+BookmarkSyncing.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/4/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension TPPSignInBusinessLogic {
  @objc func shouldShowSyncButton() -> Bool {
    guard let libraryDetails = libraryAccount?.details else {
      Log.debug(#file, "🔖 shouldShowSyncButton: NO - libraryAccount?.details is nil")
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
