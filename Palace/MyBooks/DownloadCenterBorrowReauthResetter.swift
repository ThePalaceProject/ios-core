//
//  DownloadCenterBorrowReauthResetter.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// App-side adapter conforming the MyBooks download subsystem to the
/// Accounts-declared `BorrowReauthResetting` seam (god-class decomposition
/// Wave 3, S1). Forwards the account-switch reset to the existing static
/// `MyBooksDownloadCenter.clearAllBorrowReauthState()`
/// (→ `BorrowOperation.clearAllBorrowReauthState()` → `reauthTracker.clearAll()`).
///
/// This is the concrete `BorrowReauthResetting` `AccountsManager` receives by
/// default and that `AppContainer` wires explicitly. It is a stateless struct
/// that calls a static, so it needs no `MyBooksDownloadCenter` instance — which
/// is why injecting it into `AccountsManager` (constructed before MBDC in
/// `_buildCachedAppContainer`) has no construction-order hazard. At the 3b
/// package move this adapter stays app-target composition; the protocol it
/// conforms to travels into PalaceAccounts with `AccountsManager` at 3a.
struct DownloadCenterBorrowReauthResetter: BorrowReauthResetting {
    func clearAllBorrowReauthState() {
        MyBooksDownloadCenter.clearAllBorrowReauthState()
    }
}
