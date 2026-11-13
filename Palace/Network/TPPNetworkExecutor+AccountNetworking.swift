//
//  TPPNetworkExecutor+AccountNetworking.swift
//  Palace
//
//  App-side conformance of the concrete network executor to the Accounts-owned
//  `AccountNetworking` seam. Empty body: `TPPNetworkExecutor` already declares
//  every requirement with the exact signature. The conformance lives here, on
//  the app side, so the Accounts code never names `TPPNetworkExecutor`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

extension TPPNetworkExecutor: AccountNetworking {}
