//
//  AccountsManager+Reconnect.swift
//  Palace
//
//  Kept out of the hub: AccountsManager.swift is under the file-size freeze.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

extension AccountsManager {
    /// Drives the current account's authentication document each time
    /// `connectivity` reports the network is back. A launch made offline leaves
    /// the account unloaded until then (PP-5492). The composition root binds it
    /// to the app's `Reachability`.
    func reloadCurrentAccountWhenConnected(_ connectivity: AnyPublisher<Bool, Never>) {
        authDocLoader.driveAfterEachReconnect(on: connectivity)
    }
}
