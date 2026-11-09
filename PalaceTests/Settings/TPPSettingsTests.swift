//
//  TPPSettingsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalacePreferences
import Combine
@testable import Palace

@MainActor
final class TPPSettingsTests: XCTestCase {

    private var settings: TPPSettings!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        settings = TPPSettings()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - Setter Early-Return Guard (mutation surface)

    // MARK: - Change streams

    /// Settings screens and AccountsManager each build their own TPPSettings,
    /// so a change made through one instance must reach subscribers of all.
    func testUseBetaLibrariesChange_ReachesSubscribersOfEveryInstance() {
        let suiteName = "pp5473-beta-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let otherInstance = TPPSettings(defaults: defaults)
        let received = expectation(description: "beta change")
        var values: [Bool] = []
        TPPSettings.useBetaLibrariesChanges
            .sink { values.append($0); received.fulfill() }
            .store(in: &cancellables)

        otherInstance.useBetaLibraries = true

        wait(for: [received], timeout: 5) // STARVE-001-OK: waits on one main-queue send made synchronously above; no other async work
        XCTAssertEqual(values, [true])
    }

}
