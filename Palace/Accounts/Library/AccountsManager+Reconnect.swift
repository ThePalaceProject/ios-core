//
//  AccountsManager+Reconnect.swift
//  Palace
//
//  The reconnect binding for AccountsManager, kept in its own file so the
//  account-loading entry points it adds are easy to find.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

extension AccountsManager {
    /// Drives the current account's authentication document each time
    /// `connectivity` reports the network is back. A launch made offline leaves
    /// the account unloaded until then (PP-5492). The composition root binds it
    /// to the app's `Reachability`. Binds once: a later call keeps the first
    /// subscription and returns false.
    @discardableResult
    func reloadCurrentAccountWhenConnected(_ connectivity: AnyPublisher<Bool, Never>) -> Bool {
        bindAuthDocDriveToReconnect(connectivity)
    }
}
