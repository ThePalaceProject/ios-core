//
//  BorrowReauthResetting.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Inversion of the account-switch → borrow-reauth-circuit-breaker reset
/// (god-class decomposition Wave 3, seam S1 — the ONE hard, un-inverted
/// Accounts→Downloads static edge).
///
/// On every real library switch, `AccountsManager.cleanupActiveContentBefore
/// AccountSwitch(from:to:)` must clear the process-global per-book borrow-reauth
/// **circuit breaker** (`BorrowOperation.reauthTracker`, a `static let`). The
/// breaker suppresses a *second* re-auth attempt for a book whose first borrow
/// hit an auth error, so a stale, tripped breaker carried across a library
/// switch would leave a user who switches libraries after a failed borrow
/// silently stuck on the generic-error path with NO re-auth prompt — a
/// money-path regression invisible to per-case unit tests (each resets the
/// breaker in setUp). This clear MUST reset ALL books' state, not just the
/// current book. The behavior is pinned by
/// `AccountSwitchBorrowReauthCouplingContractTests`.
///
/// Declaring the protocol on the *consuming* (Accounts) side — implemented from
/// the Downloads side above — is deliberate: at the 3a package move this file
/// travels into `PalaceAccounts`, and SwiftPM then makes the acyclicity
/// compiler-enforced (a packaged `AccountsManager` cannot name the app-target
/// `MyBooksDownloadCenter`; the concrete resetter stays app-side composition).
///
/// `Sendable`: the resetter is stored on `AccountsManager` (`@unchecked
/// Sendable`) and invoked from its account-switch cleanup; conformers hold no
/// mutable state (the adapter forwards to a static), so `Sendable` is honest.
protocol BorrowReauthResetting: Sendable {
    /// Clears ALL books' borrow-reauth circuit-breaker state. Called on a
    /// library switch so stale, tripped breaker entries from the previous
    /// library cannot suppress legitimate re-auth attempts under the new one.
    func clearAllBorrowReauthState()
}
