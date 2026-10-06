//
//  MockBackendLaunchHookTests.swift
//  PalaceTests
//
//  The DEBUG launch hook that UI journeys use to start the app against a
//  fixture scenario with a clean, deterministic state.
//

import XCTest
import PalacePreferences
@testable import Palace

final class MockBackendLaunchRequestTests: XCTestCase {

    func testRequest_WithoutAScenario_IsNil_SoANormalLaunchIsUntouched() {
        XCTAssertNil(MockBackendLaunchRequest(environment: [:]))
        XCTAssertNil(MockBackendLaunchRequest(environment: [MockBackendLaunchRequest.scenarioKey: "  "]))
        XCTAssertNil(MockBackendLaunchRequest(environment: [MockBackendLaunchRequest.resetKey: "1"]))
    }

    func testRequest_ReadsScenarioDirectoryAndReset() {
        let request = MockBackendLaunchRequest(environment: [
            MockBackendLaunchRequest.scenarioKey: "journey",
            MockBackendLaunchRequest.fixturesKey: "/fixtures",
            MockBackendLaunchRequest.resetKey: "1",
        ])

        XCTAssertEqual(request?.scenarioID, "journey")
        XCTAssertEqual(request?.fixtureDirectory, "/fixtures")
        XCTAssertEqual(request?.resetsState, true)
    }

    func testRequest_ResetsOnlyWhenTheFlagIsExactlyOne() {
        for value in ["0", "true", "", "YES"] {
            let request = MockBackendLaunchRequest(environment: [
                MockBackendLaunchRequest.scenarioKey: "journey",
                MockBackendLaunchRequest.resetKey: value,
            ])
            XCTAssertEqual(request?.resetsState, false, "reset=\(value)")
            XCTAssertNil(request?.fixtureDirectory)
        }
    }
}

final class MockBackendLaunchHookTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var fixtures: URL!
    private var appDirectory: URL!
    private var sharedStoreClears = 0
    private var registeredDefaults: [String: Any] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MockBackendLaunchHookTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        fixtures = root.appendingPathComponent("Fixtures")
        appDirectory = root.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: fixtures.appendingPathComponent("Scenarios"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try writeScenario(id: "journey", launch: MockScenarioLaunch(libraryRegistryURL: "https://palace-fixtures.test/libraries",
                                                                    libraryID: "urn:uuid:fixture-library"))
    }

    override func tearDownWithError() throws {
        MockBackendURLProtocol.flagsDidChange = nil
        MockBackendURLProtocol.activeScenario = nil
        MockBackendURLProtocol.fixtureDirectoryPath = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func writeScenario(id: String, displayName: String = "Fixture", launch: MockScenarioLaunch? = nil) throws {
        let scenario = MockScenario(id: id, displayName: displayName, description: "", routes: [], launch: launch)
        try JSONEncoder().encode(scenario)
            .write(to: fixtures.appendingPathComponent("Scenarios/\(id).json"))
    }

    private func request(_ id: String = "journey", reset: Bool) -> MockBackendLaunchRequest {
        MockBackendLaunchRequest(environment: [
            MockBackendLaunchRequest.scenarioKey: id,
            MockBackendLaunchRequest.fixturesKey: fixtures.path,
            MockBackendLaunchRequest.resetKey: reset ? "1" : "0",
        ])!
    }

    private func apply(_ request: MockBackendLaunchRequest) throws {
        try MockBackendLaunchHook.apply(
            request,
            defaults: defaults,
            appDirectories: [appDirectory],
            clearSharedStores: { sharedStoreClears += 1 },
            persistFlags: { _ in },
            registerDefaults: { registeredDefaults.merge($0) { _, new in new } }
        )
    }

    func testApply_PointsTheAppAtTheScenarioLibrary() throws {
        try apply(request(reset: false))

        XCTAssertEqual(registeredDefaults[TPPSettings.customLibraryRegistryKey] as? String,
                       "https://palace-fixtures.test/libraries")
        XCTAssertEqual(registeredDefaults[currentAccountIdentifierKey] as? String, "urn:uuid:fixture-library")
        XCTAssertEqual(registeredDefaults[TPPSettings.settingsLibraryAccountsKey] as? [String], ["urn:uuid:fixture-library"],
                       "Settings > Libraries lists only the patron's added libraries")
        XCTAssertEqual(MockBackendURLProtocol.activeScenario?.id, "journey")
        XCTAssertEqual(MockBackendURLProtocol.fixtureDirectoryPath, fixtures.path)
    }

    /// A unit-test run later on the same simulator shares the app's defaults,
    /// so the fixture library must not be written to them.
    func testApply_DoesNotPersistTheFixtureLibrary() throws {
        try apply(request(reset: true))

        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertNil(persisted[TPPSettings.customLibraryRegistryKey])
        XCTAssertNil(persisted[currentAccountIdentifierKey])
        XCTAssertNil(persisted[TPPSettings.settingsLibraryAccountsKey])
        XCTAssertEqual(registeredDefaults.count, 3, "the launch values go to the registration domain instead")
    }

    func testApply_WithReset_ClearsDefaultsFilesAndKeychainBeforeConfiguring() throws {
        defaults.set("signed-in-patron", forKey: "leftover")
        let staleFile = appDirectory.appendingPathComponent("registry.json")
        try Data("{}".utf8).write(to: staleFile)

        try apply(request(reset: true))

        XCTAssertNil(defaults.object(forKey: "leftover"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appDirectory.path), "the directory itself stays")
        XCTAssertEqual(sharedStoreClears, 1)
        XCTAssertEqual(registeredDefaults[currentAccountIdentifierKey] as? String, "urn:uuid:fixture-library",
                       "the reset must not erase what the hook then configures")
    }

    func testApply_WithoutReset_KeepsExistingStateForARelaunch() throws {
        defaults.set("signed-in-patron", forKey: "leftover")
        let file = appDirectory.appendingPathComponent("registry.json")
        try Data("{}".utf8).write(to: file)

        try apply(request(reset: false))

        XCTAssertEqual(defaults.string(forKey: "leftover"), "signed-in-patron")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(sharedStoreClears, 0)
    }

    func testApply_WithoutReset_RestoresFlagsRaisedBeforeTheRelaunch() throws {
        defaults.set(["borrowed"], forKey: MockBackendLaunchHook.flagsKey)

        try apply(request(reset: false))

        XCTAssertEqual(MockBackendURLProtocol.flags, ["borrowed"])
    }

    func testApply_WithReset_StartsWithNoFlags() throws {
        defaults.set(["borrowed"], forKey: MockBackendLaunchHook.flagsKey)

        try apply(request(reset: true))

        XCTAssertEqual(MockBackendURLProtocol.flags, [])
    }

    func testApply_UnknownScenario_ThrowsWithoutResettingAnything() throws {
        defaults.set("signed-in-patron", forKey: "leftover")

        XCTAssertThrowsError(try apply(request("missing", reset: true))) { error in
            XCTAssertEqual(error as? MockBackendLaunchHook.Failure, .scenarioNotFound("missing"))
        }
        XCTAssertEqual(defaults.string(forKey: "leftover"), "signed-in-patron")
        XCTAssertEqual(sharedStoreClears, 0)
        XCTAssertNil(MockBackendURLProtocol.activeScenario)
    }

    func testResolveScenario_PrefersTheFixtureFileOverTheEmbeddedScenarioWithTheSameID() throws {
        try writeScenario(id: "happy_path", displayName: "From fixtures")

        let scenario = try MockBackendLaunchHook.resolveScenario(request("happy_path", reset: false))

        XCTAssertEqual(scenario.displayName, "From fixtures")
    }

    func testResolveScenario_FallsBackToAnEmbeddedScenario() throws {
        let scenario = try MockBackendLaunchHook.resolveScenario(request("loan_limit", reset: false))

        XCTAssertEqual(scenario.id, "loan_limit")
        XCTAssertNil(scenario.launch, "embedded scenarios leave the registry alone")
    }
}
