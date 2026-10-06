//
//  MockBackendLaunchHook.swift
//  Palace
//
//  Starts the app against a mock backend scenario when a UI test asks for one
//  through the launch environment. Runs before `AppContainer.production()` is
//  first touched, so every session and the library registry see the scenario.
//  Compiled only in DEBUG; see docs/Testing/UI_JOURNEYS.md.
//

#if DEBUG

import Foundation
import Security
import PalaceLogging
import PalacePreferences

/// What the launch environment asked for.
struct MockBackendLaunchRequest: Equatable {
    /// The UI-test launch marker. `scripts/check-blast-radius.py` treats code
    /// that reads it as test-only when it sits under `#if DEBUG`.
    static let scenarioKey = "PALACE_MOCK_BACKEND_SCENARIO"
    static let fixturesKey = "PALACE_MOCK_BACKEND_FIXTURES"
    static let resetKey = "PALACE_MOCK_BACKEND_RESET"

    let scenarioID: String
    let fixtureDirectory: String?
    let resetsState: Bool

    /// Nil unless the environment names a scenario, so a normal launch is untouched.
    init?(environment: [String: String]) {
        guard let id = environment[MockBackendLaunchRequest.scenarioKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        scenarioID = id
        let directory = environment[Self.fixturesKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        fixtureDirectory = (directory?.isEmpty ?? true) ? nil : directory
        resetsState = environment[Self.resetKey] == "1"
    }
}

enum MockBackendLaunchHook {

    /// UserDefaults key that carries raised route flags across a relaunch.
    static let flagsKey = "debug.mockBackendLaunchFlags"

    enum Failure: Error, Equatable {
        case scenarioNotFound(String)
    }

    /// Applies a launch request from the process environment, if there is one.
    /// A request naming a scenario that cannot be found stops the app, so a UI
    /// test fails at launch instead of running against the real network.
    @MainActor
    static func applyFromProcessEnvironment() {
        guard let request = MockBackendLaunchRequest(environment: ProcessInfo.processInfo.environment) else {
            return
        }
        do {
            try apply(request, defaults: .standard, appDirectories: appDirectories())
        } catch {
            fatalError("MockBackend launch: \(error)")
        }
        // Sessions built after this point pick up the protocol, including the
        // download center's, which then uses a foreground session.
        URLProtocol.registerClass(MockBackendURLProtocol.self)
        URLSessionConfiguration.mockBackend_swizzleProtocolClasses()
    }

    /// Resets state if asked, activates the scenario, and points the app at
    /// the scenario's fixture library. Does not register the protocol; the
    /// caller does that once the configuration is in place.
    @discardableResult
    static func apply(
        _ request: MockBackendLaunchRequest,
        defaults: UserDefaults,
        appDirectories: [URL],
        fileManager: FileManager = .default,
        clearSharedStores: () -> Void = clearKeychainCookiesAndURLCache,
        persistFlags: @escaping @Sendable (Set<String>) -> Void = { flags in
            UserDefaults.standard.set(flags.sorted(), forKey: flagsKey)
        },
        registerDefaults: ([String: Any]) -> Void = { UserDefaults.standard.register(defaults: $0) }
    ) throws -> MockScenario {
        let scenario = try resolveScenario(request, fileManager: fileManager)

        if request.resetsState {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
            removeContents(of: appDirectories, fileManager: fileManager)
            clearSharedStores()
        }

        MockBackendURLProtocol.fixtureDirectoryPath = request.fixtureDirectory
        MockBackendURLProtocol.activeScenario = scenario
        MockBackendURLProtocol.flags = Set(defaults.stringArray(forKey: flagsKey) ?? [])
        MockBackendURLProtocol.flagsDidChange = persistFlags

        if let launch = scenario.launch {
            // The registration domain is read like any default but never
            // written to disk, so a unit-test run later on the same simulator,
            // which shares this app's defaults, does not inherit the fixture
            // library. It is process-wide, hence injected for tests. The
            // Libraries screen lists `settingsLibraryAccountsKey`, not the
            // current account; the first-run picker sets both.
            registerDefaults([
                TPPSettings.customLibraryRegistryKey: launch.libraryRegistryURL,
                currentAccountIdentifierKey: launch.libraryID,
                TPPSettings.settingsLibraryAccountsKey: [launch.libraryID],
            ])
        }

        Log.info(#file, "MockBackend launch: scenario '\(scenario.id)' active, reset=\(request.resetsState)")
        return scenario
    }

    /// A scenario file in the fixture directory wins over an embedded scenario
    /// with the same id.
    static func resolveScenario(
        _ request: MockBackendLaunchRequest,
        fileManager: FileManager = .default
    ) throws -> MockScenario {
        if let directory = request.fixtureDirectory {
            let path = "\(directory)/Scenarios/\(request.scenarioID).json"
            if let data = fileManager.contents(atPath: path) {
                return try JSONDecoder().decode(MockScenario.self, from: data)
            }
        }
        if let embedded = MockScenario.embeddedScenarios.first(where: { $0.id == request.scenarioID }) {
            return embedded
        }
        throw Failure.scenarioNotFound(request.scenarioID)
    }

    /// Deletes everything inside each directory, keeping the directories.
    static func removeContents(of directories: [URL], fileManager: FileManager) {
        for directory in directories {
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: []) else { continue }
            for child in children {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    /// Documents, Library/Application Support, Library/Caches and tmp: where
    /// the registry, accounts, downloads and catalog caches live.
    static func appDirectories(fileManager: FileManager = .default) -> [URL] {
        let searchPaths: [FileManager.SearchPathDirectory] = [.documentDirectory, .applicationSupportDirectory, .cachesDirectory]
        return searchPaths.compactMap { fileManager.urls(for: $0, in: .userDomainMask).first }
            + [fileManager.temporaryDirectory]
    }

    /// Credentials live in the keychain, which survives an app reinstall on
    /// the simulator, so a clean start has to delete them explicitly.
    static func clearKeychainCookiesAndURLCache() {
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        let classes = [kSecClassGenericPassword, kSecClassInternetPassword,
                       kSecClassCertificate, kSecClassKey, kSecClassIdentity]
        for secClass in classes {
            SecItemDelete([kSecClass as String: secClass] as CFDictionary)
        }
    }
}

#endif
