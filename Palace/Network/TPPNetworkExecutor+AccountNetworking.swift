//
//  TPPNetworkExecutor+AccountNetworking.swift
//  Palace
//
//  App-side conformance of the concrete network executor to the Accounts-owned
//  `AccountNetworking` seam (god-class decomposition, Wave 3 / 3a precondition).
//
//  Empty body: `TPPNetworkExecutor` already declares all three requirements with
//  the exact signatures `AccountNetworking` needs —
//    • `cancelNonEssentialTasks()`  (TPPNetworkExecutor.swift, `@objc func`)
//    • `clearCache()`               (`@objc func`)
//    • `GET(_:useTokenIfAvailable:) async throws -> (Data, URLResponse?)`
//  so this is a pure adapter that binds the app type to the package-bound protocol.
//
//  Lives next to the concrete type and STAYS app-target across the 3a move (when
//  `AccountNetworking` travels into `PalaceAccounts`, this file gains
//  `import PalaceAccounts` + `@retroactive`). Keeping the conformance here — not on
//  the protocol side — is what lets `PalaceAccounts` avoid ever naming
//  `TPPNetworkExecutor`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

extension TPPNetworkExecutor: AccountNetworking {}
