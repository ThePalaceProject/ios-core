//
//  AccountScopeProviding.swift
//  PalaceBookRegistry
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// The complete account-scope surface the registry consumes (god-class
/// decomposition Wave 2b — the Book→Accounts dependency inversion). Deliberately
/// value-only: no `Account`, `AccountDetails`, `AccountsManager`, or
/// `TPPUserAccount` type ever crosses this boundary. Adapted app-side by
/// `AccountsManagerAccountScopeAdapter`.
public protocol AccountScopeProviding: Sendable {
    /// uuid of the currently selected library account; nil before selection.
    /// (adapter: `accountsManager.currentAccount?.uuid` / `currentAccountId`.)
    var currentAccountID: String? { get }

    /// Fires when the current library changes. No delivery-thread promise —
    /// the registry keeps its own `.receive(on: RunLoop.main)`, exactly as
    /// before the inversion.
    /// (adapter: `NotificationCenter.publisher(for: .TPPCurrentAccountDidChange).map { _ in }`.)
    var accountDidChangePublisher: AnyPublisher<Void, Never> { get }

    /// True when stored credentials exist for the given library.
    /// (adapter: `TPPUserAccount.sharedAccount(libraryUUID: id).hasCredentials()`.)
    func hasCredentials(forAccount accountID: String) -> Bool

    /// Await account-details readiness, then return the loans-feed URL.
    /// `nil` = anonymous library (no `loansUrl` after ready). Throws = the
    /// account failed to become ready (the registry reverts state to `.loaded`
    /// and retries via its own policy — unchanged).
    /// (adapter: `accountsManager.account(id)?.awaitReady(timeout:).loansUrl`.)
    ///
    /// - Parameter readinessTimeout: Seconds to wait for the account to reach a
    ///   terminal load state before throwing. The registry — which owns the retry
    ///   cadence — supplies the bound; conformers MUST NOT wait longer than it.
    ///   An unbounded implementation reintroduces the HelpSpot #18414 wedge: a
    ///   dropped `authentication_document` completion parks the account at
    ///   `.detailsLoading`, registry sync never completes, and My Books spins
    ///   forever with no self-heal short of a sign-out.
    func loansURL(forAccount accountID: String, readinessTimeout: TimeInterval) async throws -> URL?
}
