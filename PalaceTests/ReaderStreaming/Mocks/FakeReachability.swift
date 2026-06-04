//
//  FakeReachability.swift
//  PalaceTests
//
//  Lightweight test double for `ReachabilityProviding` (the seam introduced
//  for StreamingReader). Returns a stubbed `isConnectedToNetwork()` so the
//  VM's offline-state branch is deterministic on CI.
//

import Foundation
@testable import Palace

final class FakeReachability: ReachabilityProviding {
    var stubbedConnected: Bool

    init(connected: Bool) {
        self.stubbedConnected = connected
    }

    func isConnectedToNetwork() -> Bool {
        stubbedConnected
    }
}
