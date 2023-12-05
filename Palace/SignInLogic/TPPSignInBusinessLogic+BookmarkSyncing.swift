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
      return false
    }

    return libraryDetails.supportsSimplyESync &&
      libraryDetails.getLicenseURL(.annotations) != nil &&
      userAccount.hasCredentials() &&
      libraryAccountID == libraryAccountsProvider.currentAccount?.uuid
  }
}
