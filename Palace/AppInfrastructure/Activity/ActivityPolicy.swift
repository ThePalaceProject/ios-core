//
//  ActivityPolicy.swift
//  Palace
//
//  One place that knows whether anyone can see the app, and how hot and
//  power-limited the device is (PP-5508). Inputs are pushed in by their
//  owners; decisions come from ActivityRules.
//

import Combine
import Foundation
import os
import UIKit

/// Source of periodic ticks. Production uses a main run-loop timer.
protocol ActivityTickScheduling: AnyObject {
    func ticks(every interval: TimeInterval) -> AnyPublisher<Date, Never>
}

final class TimerTickScheduler: ActivityTickScheduling {
    func ticks(every interval: TimeInterval) -> AnyPublisher<Date, Never> {
        Timer.publish(every: interval, on: .main, in: .common).autoconnect().eraseToAnyPublisher()
    }
}

/// Owned by `AppContainer`. Sources push into it through setters; it holds
/// no reference to any of them, so a source may keep it without a cycle.
@MainActor
final class ActivityPolicy {
    private let subject: CurrentValueSubject<ActivityState, Never>
    private let scheduler: ActivityTickScheduling
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let isLowPowerModeEnabled: @Sendable () -> Bool
    private let signposter: OSSignposter
    private var cancellables = Set<AnyCancellable>()

    var state: ActivityState { subject.value }

    var statePublisher: AnyPublisher<ActivityState, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    init(
        notificationCenter: NotificationCenter,
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState,
        isLowPowerModeEnabled: @escaping @Sendable () -> Bool,
        scheduler: ActivityTickScheduling,
        signposter: OSSignposter = OSSignposter(subsystem: "org.thepalaceproject.palace", category: "ActivityPolicy")
    ) {
        var initial = ActivityState.launch
        initial.thermal = thermalState()
        initial.lowPowerMode = isLowPowerModeEnabled()
        self.subject = CurrentValueSubject(initial)
        self.scheduler = scheduler
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.signposter = signposter

        // Thermal and power notifications can be posted on any thread.
        observe(ProcessInfo.thermalStateDidChangeNotification, on: notificationCenter) { $0.refreshDeviceConditions() }
        observe(.NSProcessInfoPowerStateDidChange, on: notificationCenter) { $0.refreshDeviceConditions() }
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification, on: notificationCenter) {
            $0.setProtectedDataAvailable(false)
        }
        observe(UIApplication.protectedDataDidBecomeAvailableNotification, on: notificationCenter) {
            $0.setProtectedDataAvailable(true)
        }
    }

    // MARK: - Inputs

    func setScene(_ scene: SceneVisibility) {
        update { $0.scene = scene }
    }

    func setCarPlayConnected(_ connected: Bool) {
        update { $0.carPlayConnected = connected }
    }

    func setProtectedDataAvailable(_ available: Bool) {
        update { $0.protectedDataAvailable = available }
    }

    func setPlayer(_ player: PlayerVisibility) {
        update { $0.player = player }
    }

    // MARK: - Decisions

    func interval(for category: ActivityCategory) -> TimeInterval? {
        ActivityRules.interval(for: category, in: state)
    }

    func ambientSync() -> AmbientSyncDecision {
        let decision = ActivityRules.ambientSync(in: state)
        signposter.emitEvent("ambientSync", "\(decision.rawValue, privacy: .public)")
        return decision
    }

    /// Marks a deferred ambient sync running on the transition to visible,
    /// so a device trace counts runs as well as decisions.
    func recordDeferredAmbientSyncRun() {
        signposter.emitEvent("ambientSync", "ranOnVisible")
    }

    /// Ticks at the category's current interval. Re-arms when the interval
    /// changes and emits nothing while it is nil.
    func ticks(for category: ActivityCategory) -> AnyPublisher<Date, Never> {
        let scheduler = self.scheduler
        let signposter = self.signposter
        return subject
            .map { ActivityRules.interval(for: category, in: $0) }
            .removeDuplicates()
            .map { interval -> AnyPublisher<Date, Never> in
                signposter.emitEvent(
                    "interval",
                    "\(category.rawValue, privacy: .public) \(interval ?? 0, privacy: .public)"
                )
                guard let interval else { return Empty().eraseToAnyPublisher() }
                return scheduler.ticks(every: interval)
            }
            .switchToLatest()
            .eraseToAnyPublisher()
    }

    // MARK: - Private

    private func update(_ change: (inout ActivityState) -> Void) {
        var next = subject.value
        change(&next)
        guard next != subject.value else { return }
        subject.send(next)
    }

    private func refreshDeviceConditions() {
        let thermal = thermalState()
        let lowPower = isLowPowerModeEnabled()
        update {
            $0.thermal = thermal
            $0.lowPowerMode = lowPower
        }
    }

    /// Hops to the main queue before touching state, so a post from a
    /// background thread never runs main-actor code off main.
    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter,
        _ action: @escaping @MainActor (ActivityPolicy) -> Void
    ) {
        center.publisher(for: name)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                action(self)
            }
            .store(in: &cancellables)
    }
}
