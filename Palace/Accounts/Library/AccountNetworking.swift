//
//  AccountNetworking.swift
//  Palace
//
//  god-class decomposition — Wave 3 seam (3a precondition).
//
//  The narrow slice of the shared network executor that `AccountsManager` actually
//  uses on the account-switch cleanup + catalog/auth-doc fetch paths. Declaring it
//  as a protocol beside `AccountsManager` removes the manager's last concrete
//  reference to the app-target `TPPNetworkExecutor` type: S3 already inverted the
//  ambient REACH (the executor is resolved through `AccountSwitchDependencies`'s
//  injected provider closure rather than reaching the composition root directly),
//  but the property and provider were still concretely typed. A SwiftPM `PalaceAccounts`
//  target cannot name a `Palace/Network` app-target type, so this seam is the
//  documented precondition for the 3a package move.
//
//  Declared in the consuming (lower) module and implemented from above — the
//  `BorrowReauthResetting` (S1) / `DownloadUserAccount` (S2) precedent. At the 3a
//  move this protocol travels INTO `PalaceAccounts` with `AccountsManager`; the
//  app-side `extension TPPNetworkExecutor: AccountNetworking` (in
//  `TPPNetworkExecutor+AccountNetworking.swift`) stays app-target and gains an
//  `import PalaceAccounts` + `@retroactive` then.
//
//  `AnyObject, Sendable`: the concrete witness `TPPNetworkExecutor` is already
//  `@objc class … NSObject, @unchecked Sendable`, so this adds ZERO new Sendable
//  obligation, matches the existing `@Sendable () -> TPPNetworkExecutor` provider,
//  and is REQUIRED — the async `GET` is awaited inside an owned-crawl `@Sendable`
//  Task, so the existential must be `Sendable` to survive that capture.
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
