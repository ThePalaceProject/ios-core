//
//  BorrowReauthResetting.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Lets `AccountsManager` reset the borrow-reauth circuit breaker on a library
/// switch without depending on the Downloads side.
///
/// The breaker (`BorrowOperation.reauthTracker`, process-global) suppresses a
/// second re-auth attempt for a book whose first borrow hit an auth error. A
/// tripped breaker carried across a library switch would leave the patron on
/// the generic-error path with no re-auth prompt, so the reset must clear all
/// books. Pinned by `AccountSwitchBorrowReauthCouplingContractTests`.
///
/// Declared on the consuming (Accounts) side so a future `PalaceAccounts`
/// package cannot name `MyBooksDownloadCenter`. Conformers hold no mutable
/// state, so `Sendable` holds.
protocol BorrowReauthResetting: Sendable {
    /// Clears ALL books' borrow-reauth circuit-breaker state. Called on a
    /// library switch so stale, tripped breaker entries from the previous
    /// library cannot suppress legitimate re-auth attempts under the new one.
    func clearAllBorrowReauthState()
}
