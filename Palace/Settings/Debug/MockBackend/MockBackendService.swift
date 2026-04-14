//
//  MockBackendService.swift
//  Palace
//
//  Manager for the mock backend. Activates/deactivates URL interception,
//  loads scenarios, and persists the current selection.
//
//  Used by both the debug menu (runtime) and XCTest (test-time).
//

#if DEBUG

import Foundation
import Combine

final class MockBackendService: ObservableObject {

    static let shared = MockBackendService()

    // MARK: - Published State

    @Published private(set) var isActive: Bool = false
    @Published private(set) var currentScenario: MockScenario?
    @Published private(set) var availableScenarios: [MockScenario] = []

    // MARK: - UserDefaults Keys

    private static let enabledKey = "debug.mockBackendEnabled"
    private static let scenarioKey = "debug.mockBackendScenario"

    // MARK: - Init

    private init() {
        loadScenarios()
        restoreState()
    }

    /// Test-friendly initializer — does not auto-restore state.
    init(scenarios: [MockScenario]) {
        self.availableScenarios = scenarios
    }

    // MARK: - Scenario Management

    func loadScenarios(from bundle: Bundle = .main) {
        // Use embedded Swift scenarios (always available, no bundle required)
        availableScenarios = MockScenario.embeddedScenarios

        // Also try loading from bundle/disk for custom scenarios
        let bundleScenarios = MockScenario.loadAll(from: bundle)
        if !bundleScenarios.isEmpty {
            let embeddedIds = Set(availableScenarios.map(\.id))
            let custom = bundleScenarios.filter { !embeddedIds.contains($0.id) }
            availableScenarios.append(contentsOf: custom)
        }

        Log.info(#file, "MockBackend: loaded \(availableScenarios.count) scenarios")
    }

    // MARK: - Activation

    func activate(scenario: MockScenario) {
        Log.info(#file, "MockBackend: activating scenario '\(scenario.displayName)'")

        MockBackendURLProtocol.activeScenario = scenario
        MockBackendURLProtocol.fixtureBundle = fixtureBundle()

        // Register globally for URLSession.shared
        URLProtocol.registerClass(MockBackendURLProtocol.self)

        // Swizzle URLSessionConfiguration so new sessions get the protocol
        URLSessionConfiguration.mockBackend_swizzleProtocolClasses()

        // Recreate TPPNetworkExecutor's internal session so it picks up
        // the swizzled protocol classes. This is the only way to intercept
        // requests from an already-created URLSession.
        TPPNetworkExecutor.shared.recreateSession()

        currentScenario = scenario
        isActive = true

        // Persist selection
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        UserDefaults.standard.set(scenario.id, forKey: Self.scenarioKey)
    }

    func deactivate() {
        Log.info(#file, "MockBackend: deactivating")

        MockBackendURLProtocol.activeScenario = nil
        URLProtocol.unregisterClass(MockBackendURLProtocol.self)
        URLSessionConfiguration.mockBackend_unswizzleProtocolClasses()

        // Recreate session to remove the mock protocol
        TPPNetworkExecutor.shared.recreateSession()

        currentScenario = nil
        isActive = false

        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.scenarioKey)
    }

    // MARK: - State Restoration

    private func restoreState() {
        let wasEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        guard wasEnabled else { return }

        let scenarioId = UserDefaults.standard.string(forKey: Self.scenarioKey)
        if let id = scenarioId,
           let scenario = availableScenarios.first(where: { $0.id == id }) {
            activate(scenario: scenario)
        }
    }

    // MARK: - Bundle Resolution

    private func fixtureBundle() -> Bundle {
        // In the app, fixtures are in the main bundle (DEBUG builds only)
        // In tests, they're in the test bundle
        return .main
    }

    // MARK: - Disk Loading (Development Fallback)

    private func loadScenariosFromDisk() -> [MockScenario] {
        // Try to find scenarios relative to the project root
        // This works during development when fixtures aren't bundled yet
        let possiblePaths = [
            "PalaceTests/Fixtures/API/Scenarios",
            "../PalaceTests/Fixtures/API/Scenarios",
        ]

        for path in possiblePaths {
            let url = URL(fileURLWithPath: path)
            guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "json" }) else { continue }

            return files.compactMap { fileURL in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return try? JSONDecoder().decode(MockScenario.self, from: data)
            }.sorted { $0.displayName < $1.displayName }
        }

        return []
    }
}

#endif
