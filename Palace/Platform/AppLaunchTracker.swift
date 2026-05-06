//
//  AppLaunchTracker.swift
//  Palace
//
//  Tracks cold and warm app launch timing milestones.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import os.signpost

/// Milestones in the app launch sequence.
enum LaunchMilestone: String, Sendable, CaseIterable {
    case processStart = "process_start"
    case didFinishLaunching = "did_finish_launching"
    case firstFrame = "first_frame"
    case catalogLoaded = "catalog_loaded"
}

/// Tracks app launch timing through key milestones.
actor AppLaunchTracker {

    // MARK: - Singleton

    static let shared = AppLaunchTracker()

    // MARK: - State

    private var milestones: [LaunchMilestone: CFAbsoluteTime] = [:]
    private var isWarmLaunch: Bool = false
    private let signpostLog = OSLog(subsystem: "org.thepalaceproject.palace", category: "AppLaunch")
    private var signpostID: OSSignpostID?
    private let performanceMonitor: PerformanceMonitor

    // MARK: - Init

    init(performanceMonitor: PerformanceMonitor = .shared) {
        self.performanceMonitor = performanceMonitor
    }

    // MARK: - Recording

    /// Record a milestone timestamp. Call this at each key point in the launch sequence.
    func recordMilestone(_ milestone: LaunchMilestone) {
        let now = CFAbsoluteTimeGetCurrent()
        milestones[milestone] = now

        if milestone == .processStart {
            signpostID = OSSignpostID(log: signpostLog)
            if let id = signpostID {
                os_signpost(.begin, log: signpostLog, name: "AppLaunch", signpostID: id, "Launch started")
            }
        }

        if milestone == .catalogLoaded || milestone == .firstFrame {
            if let id = signpostID {
                os_signpost(.end, log: signpostLog, name: "AppLaunch", signpostID: id, "%{public}s", milestone.rawValue)
            }
        }

        // When catalog is loaded, report the full launch timing
        if milestone == .catalogLoaded {
            Task {
                await reportLaunchMetrics()
            }
        }
    }

    /// Mark this as a warm launch (app was in background).
    func markWarmLaunch() {
        isWarmLaunch = true
    }

    /// Reset for a new launch measurement.
    func reset() {
        milestones.removeAll()
        isWarmLaunch = false
        signpostID = nil
    }

    // MARK: - Queries

    /// Time between two milestones in seconds, or nil if either hasn't been recorded.
    func timeBetween(_ start: LaunchMilestone, _ end: LaunchMilestone) -> TimeInterval? {
        guard let startTime = milestones[start], let endTime = milestones[end] else {
            return nil
        }
        return endTime - startTime
    }

    /// Time to interactive: process start to catalog loaded.
    var timeToInteractive: TimeInterval? {
        timeBetween(.processStart, .catalogLoaded)
    }

    /// Time to first frame: process start to first frame rendered.
    var timeToFirstFrame: TimeInterval? {
        timeBetween(.processStart, .firstFrame)
    }

    /// Whether this was a cold or warm launch.
    var launchType: String {
        isWarmLaunch ? "warm" : "cold"
    }

    /// All recorded milestones with their timestamps.
    var recordedMilestones: [LaunchMilestone: CFAbsoluteTime] {
        milestones
    }

    // MARK: - Private

    private func reportLaunchMetrics() async {
        if let tti = timeToInteractive {
            await performanceMonitor.record(
                name: "time_to_interactive_\(launchType)",
                category: .appLaunch,
                duration: tti,
                metadata: ["launch_type": launchType]
            )
        }

        if let ttf = timeToFirstFrame {
            await performanceMonitor.record(
                name: "time_to_first_frame_\(launchType)",
                category: .appLaunch,
                duration: ttf,
                metadata: ["launch_type": launchType]
            )
        }

        if let configToFrame = timeBetween(.didFinishLaunching, .firstFrame) {
            await performanceMonitor.record(
                name: "config_to_frame_\(launchType)",
                category: .appLaunch,
                duration: configToFrame,
                metadata: ["launch_type": launchType]
            )
        }
    }
}
