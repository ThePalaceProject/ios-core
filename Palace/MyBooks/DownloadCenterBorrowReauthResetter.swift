//
//  DownloadCenterBorrowReauthResetter.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// App-side adapter conforming the MyBooks download subsystem to the
/// Accounts-declared `BorrowReauthResetting` seam. Forwards the account-switch
/// reset to the static `MyBooksDownloadCenter.clearAllBorrowReauthState()`.
///
/// Stateless and instance-free, so injecting it into `AccountsManager` (built
/// before `MyBooksDownloadCenter` in `_buildCachedAppContainer`) has no
/// construction-order hazard.
struct DownloadCenterBorrowReauthResetter: BorrowReauthResetting {
    func clearAllBorrowReauthState() {
        MyBooksDownloadCenter.clearAllBorrowReauthState()
    }
}
