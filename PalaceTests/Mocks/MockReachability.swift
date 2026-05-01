//
//  MockReachability.swift
//  PalaceTests
//
//  Test double for `Reachability`. Lets tests drive `isConnectedToNetwork()`
//  and `connectivityPublisher` without booting `NWPathMonitor` or hitting the
//  host's actual connectivity. Used by PP-4114 regression tests so offline
//  behavior is deterministic on CI.
//

import Combine
import Foundation
import PalaceNetwork

final class MockReachability: Reachability {
    private let subject: CurrentValueSubject<Bool, Never>
    private var stubbedConnected: Bool

    init(initiallyConnected: Bool = true) {
        self.subject = CurrentValueSubject<Bool, Never>(initiallyConnected)
        self.stubbedConnected = initiallyConnected
        super.init()
    }

    override var connectivityPublisher: AnyPublisher<Bool, Never> {
        subject
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    override func isConnectedToNetwork() -> Bool {
        stubbedConnected
    }

    /// Drive a connectivity transition from tests. Mirrors what the real
    /// `NWPathMonitor` callback does: updates the underlying state and then
    /// publishes to subscribers.
    func simulate(connected: Bool) {
        stubbedConnected = connected
        subject.send(connected)
    }
}
