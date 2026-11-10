//
//  FakeActivityTickScheduler.swift
//  PalaceTests
//
//  Tick source for ActivityPolicy consumers: records each arm and fires an
//  arm on demand, so a timer's pause and resume are observable without time.
//

import Combine
import Foundation
@testable import Palace

final class FakeActivityTickScheduler: ActivityTickScheduling, @unchecked Sendable {
    private(set) var armedIntervals: [TimeInterval] = []
    private var subjects: [PassthroughSubject<Date, Never>] = []

    func ticks(every interval: TimeInterval) -> AnyPublisher<Date, Never> {
        armedIntervals.append(interval)
        let subject = PassthroughSubject<Date, Never>()
        subjects.append(subject)
        return subject.eraseToAnyPublisher()
    }

    /// Fires every arm made so far. A replaced or stopped arm has no
    /// subscriber left, so only a live arm can deliver.
    func fireAll(at date: Date = Date(timeIntervalSince1970: 0)) {
        subjects.forEach { $0.send(date) }
    }
}

@MainActor
func makeTestActivityPolicy(scheduler: ActivityTickScheduling) -> ActivityPolicy {
    ActivityPolicy(
        notificationCenter: NotificationCenter(),
        thermalState: { .nominal },
        isLowPowerModeEnabled: { false },
        scheduler: scheduler
    )
}
