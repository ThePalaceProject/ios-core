//
//  ActivityRulesTests.swift
//  PalaceTests
//
//  Exhaustive table for ActivityRules (PP-5508): every category and the
//  ambient-sync decision over every reachable ActivityState.
//

import XCTest
@testable import Palace

final class ActivityRulesTests: XCTestCase {

    // MARK: - State space

    private static let thermalStates: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]

    /// Every combination of every input: 3 scenes x 2 CarPlay x 2 protected
    /// data x 4 thermal x 2 Low Power x 4 player = 384 states.
    private static let allStates: [ActivityState] = {
        var states: [ActivityState] = []
        for scene in SceneVisibility.allCases {
            for carPlay in [false, true] {
                for protectedData in [false, true] {
                    for thermal in thermalStates {
                        for lowPower in [false, true] {
                            for player in PlayerVisibility.allCases {
                                states.append(ActivityState(
                                    scene: scene,
                                    carPlayConnected: carPlay,
                                    protectedDataAvailable: protectedData,
                                    thermal: thermal,
                                    lowPowerMode: lowPower,
                                    player: player
                                ))
                            }
                        }
                    }
                }
            }
        }
        return states
    }()

    // MARK: - Expected table (design 3.2-3.4, written as literal rows)

    /// Visible = main scene active or inactive, or CarPlay connected.
    private func expectedVisible(_ s: ActivityState) -> Bool {
        switch (s.scene, s.carPlayConnected) {
        case (.active, _), (.inactive, _): return true
        case (.background, true): return true
        case (.background, false): return false
        }
    }

    private func expectedConstrained(_ s: ActivityState) -> Bool {
        switch s.thermal {
        case .serious, .critical: return true
        case .nominal, .fair: return s.lowPowerMode
        @unknown default: return s.lowPowerMode
        }
    }

    private func expectedInterval(_ category: ActivityCategory, _ s: ActivityState) -> TimeInterval? {
        let constrained = expectedConstrained(s)
        switch category {
        case .uiTick:
            // Main scene only: a CarPlay screen does not show the player ticker.
            let mainSceneVisible = s.scene == .active || s.scene == .inactive
            switch (mainSceneVisible, s.player, constrained) {
            case (false, _, _): return nil
            case (true, .none, _), (true, .hidden, _): return nil
            case (true, .mini, false), (true, .expanded, false): return 0.2
            case (true, .mini, true), (true, .expanded, true): return 0.4
            }
        case .housekeeping:
            switch (expectedVisible(s), constrained) {
            case (false, _): return nil
            case (true, false): return 60
            case (true, true): return 120
            }
        case .telemetryUpload:
            return expectedVisible(s) ? 60 : 900
        }
    }

    // MARK: - Generated table

    func testInterval_everyCategoryInEveryState_matchesTheDesignTable() {
        XCTAssertEqual(Self.allStates.count, 384)
        var mismatches: [String] = []
        for category in ActivityCategory.allCases {
            for state in Self.allStates {
                let actual = ActivityRules.interval(for: category, in: state)
                let expected = expectedInterval(category, state)
                if actual != expected {
                    mismatches.append("\(category) \(state): expected \(String(describing: expected)), got \(String(describing: actual))")
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) cells differ:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }

    func testAmbientSync_everyState_runsNowWhenVisibleAndDefersOnlyInBackgroundWithoutCarPlay() {
        var mismatches: [String] = []
        for state in Self.allStates {
            let expected: AmbientSyncDecision = expectedVisible(state) ? .runNow : .deferUntilVisible
            let actual = ActivityRules.ambientSync(in: state)
            if actual != expected {
                mismatches.append("\(state): expected \(expected), got \(actual)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) cells differ:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }

    // MARK: - Invariants over the whole table

    /// Protected data is detail only; it is never the reason to skip work.
    func testEveryDecision_isUnchangedByProtectedDataAvailability() {
        for state in Self.allStates where state.protectedDataAvailable {
            var locked = state
            locked.protectedDataAvailable = false
            XCTAssertEqual(ActivityRules.ambientSync(in: locked), ActivityRules.ambientSync(in: state), "\(state)")
            for category in ActivityCategory.allCases {
                XCTAssertEqual(ActivityRules.interval(for: category, in: locked),
                               ActivityRules.interval(for: category, in: state), "\(category) \(state)")
            }
        }
    }

    /// Thermal pressure and Low Power slow work down but never turn it off.
    func testThermalAndLowPower_neverTurnARunningCategoryOff() {
        for state in Self.allStates where state.thermal == .nominal && !state.lowPowerMode {
            for category in ActivityCategory.allCases {
                guard let relaxed = ActivityRules.interval(for: category, in: state) else { continue }
                for thermal in Self.thermalStates {
                    for lowPower in [false, true] {
                        var hot = state
                        hot.thermal = thermal
                        hot.lowPowerMode = lowPower
                        let constrained = ActivityRules.interval(for: category, in: hot)
                        XCTAssertNotNil(constrained, "\(category) \(hot)")
                        XCTAssertGreaterThanOrEqual(constrained ?? 0, relaxed, "\(category) \(hot)")
                    }
                }
            }
        }
    }

    // MARK: - Named cells called out by the design

    func testAmbientSync_inactiveSceneDuringConsentSheet_runsNow() {
        let state = ActivityState(scene: .inactive, carPlayConnected: false, protectedDataAvailable: true,
                                  thermal: .nominal, lowPowerMode: false, player: .none)
        XCTAssertEqual(ActivityRules.ambientSync(in: state), .runNow)
    }

    func testUITick_playerHiddenByReader_isOff() {
        let state = ActivityState(scene: .active, carPlayConnected: false, protectedDataAvailable: true,
                                  thermal: .nominal, lowPowerMode: false, player: .hidden)
        XCTAssertNil(ActivityRules.interval(for: .uiTick, in: state))
    }

    func testUITick_backgroundWithCarPlay_isOffBecauseCarPlayDoesNotShowTheTicker() {
        let state = ActivityState(scene: .background, carPlayConnected: true, protectedDataAvailable: true,
                                  thermal: .nominal, lowPowerMode: false, player: .expanded)
        XCTAssertNil(ActivityRules.interval(for: .uiTick, in: state))
        XCTAssertEqual(ActivityRules.interval(for: .housekeeping, in: state), 60)
    }

    func testLaunchState_isBackgroundUntilAMainSceneReports() {
        XCTAssertEqual(ActivityRules.ambientSync(in: .launch), .deferUntilVisible)
    }
}
