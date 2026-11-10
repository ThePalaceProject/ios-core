//
//  ActivityRules.swift
//  Palace
//
//  The decisions behind ActivityPolicy (PP-5508), as pure functions so every
//  cell of the rules table can be tested without a scene or a timer.
//

import Foundation

/// The main scene's lifecycle phase. Before any main scene connects the app
/// counts as `.background`.
enum SceneVisibility: CaseIterable, Sendable {
    case background, inactive, active
}

/// `.hidden`: a session exists but a reader covers the mini player.
enum PlayerVisibility: CaseIterable, Sendable {
    case none, hidden, mini, expanded
}

/// Periodic work that asks the policy how often to run.
enum ActivityCategory: String, CaseIterable, Sendable {
    /// Player UI refresh (the audio-wait ticker and the UI consumer rate).
    case uiTick
    /// Cache eviction and similar upkeep.
    case housekeeping
    /// Audiobook play-time upload.
    case telemetryUpload
    /// The audiobook preview's remaining-time label.
    case previewCountdown
}

enum AmbientSyncDecision: String, Sendable {
    case runNow
    case deferUntilVisible
}

struct ActivityState: Equatable, Sendable {
    var scene: SceneVisibility
    var carPlayConnected: Bool
    /// False while the device is locked with a passcode. Detail only: no rule
    /// skips work on this alone, because without a passcode it never changes.
    var protectedDataAvailable: Bool
    var thermal: ProcessInfo.ThermalState
    var lowPowerMode: Bool
    var player: PlayerVisibility

    static let launch = ActivityState(
        scene: .background,
        carPlayConnected: false,
        protectedDataAvailable: true,
        thermal: .nominal,
        lowPowerMode: false,
        player: .none
    )
}

/// Rules from the PP-5508 design.
/// Visible means the main scene is active or inactive, or CarPlay is
/// connected. `.inactive` counts as visible because it covers Control Center,
/// call banners and the OIDC consent sheet, where the patron returns within
/// seconds and expects current data.
enum ActivityRules {
    static let uiTickInterval: TimeInterval = 0.2
    static let housekeepingInterval: TimeInterval = 60
    /// The same in every state: going to the background sends the queue at
    /// once (`PlaytimeUploadSchedule`), so a visible app gains nothing from a
    /// shorter interval.
    static let telemetryUploadInterval: TimeInterval = 15 * 60
    static let previewCountdownInterval: TimeInterval = 1

    /// How often `category` should run, or nil when it should not run.
    static func interval(for category: ActivityCategory, in state: ActivityState) -> TimeInterval? {
        switch category {
        case .uiTick:
            // The player ticker is drawn only by the main scene, never by CarPlay.
            guard isMainSceneVisible(state), isPlayerOnScreen(state.player) else { return nil }
            return isConstrained(state) ? uiTickInterval * 2 : uiTickInterval
        case .housekeeping:
            guard isVisible(state) else { return nil }
            return isConstrained(state) ? housekeepingInterval * 2 : housekeepingInterval
        case .telemetryUpload:
            return telemetryUploadInterval
        case .previewCountdown:
            // Drawn only by the main scene. Never slowed: a slower countdown skips seconds.
            return isMainSceneVisible(state) ? previewCountdownInterval : nil
        }
    }

    /// Whether a sync nobody asked for (an auth-state change) runs now or
    /// waits for the next transition to visible.
    static func ambientSync(in state: ActivityState) -> AmbientSyncDecision {
        isVisible(state) ? .runNow : .deferUntilVisible
    }

    static func isVisible(_ state: ActivityState) -> Bool {
        isMainSceneVisible(state) || state.carPlayConnected
    }

    private static func isMainSceneVisible(_ state: ActivityState) -> Bool {
        state.scene != .background
    }

    private static func isPlayerOnScreen(_ player: PlayerVisibility) -> Bool {
        switch player {
        case .mini, .expanded: return true
        case .none, .hidden: return false
        }
    }

    /// Thermal pressure or Low Power slows work down; it never turns it off.
    private static func isConstrained(_ state: ActivityState) -> Bool {
        switch state.thermal {
        case .serious, .critical: return true
        default: return state.lowPowerMode
        }
    }
}
