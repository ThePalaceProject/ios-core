//
//  AccountNetworking.swift
//  Palace
//
//  The slice of the network executor `AccountsManager` uses, as a protocol so
//  Accounts does not name the app-target `TPPNetworkExecutor` (a precondition
//  for moving Accounts into a `PalaceAccounts` package). Declared on the
//  consuming side, implemented app-side in `TPPNetworkExecutor+AccountNetworking.swift`.
//  `Sendable` is required: `GET` is awaited inside a `@Sendable` crawl Task.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The account-facing surface of the shared network executor: the three calls
/// `AccountsManager` makes on the account-switch cleanup path (`cancelNonEssentialTasks`),
/// the cache-clear path (`clearCache`), and the catalog/auth-doc fetch path (`GET`).
/// `TPPNetworkExecutor` conforms app-side; tests inject a plain recording double.
protocol AccountNetworking: AnyObject, Sendable {
    /// Cancel in-flight, non-essential requests before an account switch so a
    /// request started under the prior library's credentials cannot land against
    /// the new one. Synchronous on purpose (mirrors the executor's contract).
    func cancelNonEssentialTasks()

    /// Clear the network response cache as part of `AccountsManager.clearCache()`.
    func clearCache()

    /// Fetch catalog / auth-document bytes. `useTokenIfAvailable` matches the
    /// executor's parameter; the account paths always pass it explicitly.
    func GET(_ reqURL: URL, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?)
}
