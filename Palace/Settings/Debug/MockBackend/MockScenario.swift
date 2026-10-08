//
//  MockScenario.swift
//  Palace
//
//  Declarative scenario model for the mock backend service.
//  Each scenario maps URL patterns to fixture responses, enabling
//  QA to test any backend state from the debug menu.
//

#if DEBUG

import Foundation
import PalaceLogging

/// A test scenario that defines how the mock backend responds to each URL pattern.
struct MockScenario: Codable, Identifiable {
    let id: String
    let displayName: String
    let description: String
    let routes: [MockRoute]

    /// App state a launch-time activation applies before any service starts.
    /// Only `MockBackendLaunchHook` reads it; the debug menu ignores it.
    var launch: MockScenarioLaunch?

    /// Load a scenario from a JSON file in the given bundle.
    static func load(_ name: String, from bundle: Bundle) -> MockScenario? {
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Scenarios") ??
                        bundle.url(forResource: name, withExtension: "json") else {
            Log.warn(#file, "MockScenario: fixture \(name).json not found in bundle")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(MockScenario.self, from: data)
        } catch {
            Log.error(#file, "MockScenario: failed to decode \(name).json: \(error)")
            return nil
        }
    }

    /// Load all scenarios from a bundle's Scenarios/ directory.
    static func loadAll(from bundle: Bundle) -> [MockScenario] {
        guard let scenariosURL = bundle.url(forResource: "Scenarios", withExtension: nil) ??
                                  bundle.resourceURL?.appendingPathComponent("Scenarios") else {
            return []
        }

        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: scenariosURL,
                                                                includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else {
            return []
        }

        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(MockScenario.self, from: data)
        }.sorted { $0.displayName < $1.displayName }
    }
}

/// App state applied at launch so the app starts against the scenario's
/// fixture library instead of the production registry.
struct MockScenarioLaunch: Codable, Equatable {
    /// Full URL of the fixture library registry feed.
    let libraryRegistryURL: String

    /// Registry id of the library to select at launch.
    let libraryID: String
}

/// A single route in a mock scenario — maps a URL pattern to a fixture response.
struct MockRoute: Codable {
    /// HTTP method to match (nil matches any method).
    let method: String?

    /// Regex pattern matched against the full request URL.
    let pathPattern: String

    /// Name of the fixture file (without extension) in the Fixtures/API/ directory.
    let fixtureName: String

    /// Optional key within a fixture file (for dictionaries like problem_documents.json).
    let fixtureKey: String?

    /// HTTP status code to return.
    let statusCode: Int

    /// Content-Type header value.
    let contentType: String

    /// Optional simulated network delay in milliseconds.
    let delayMs: Int?

    /// Optional additional response headers.
    let headers: [String: String]?

    /// When set, the route matches only while this flag is raised. Lets one
    /// scenario answer the same URL differently before and after an action,
    /// such as the loans feed before and after a borrow.
    let requiresFlag: String?

    /// When set, serving this route raises the flag.
    let setsFlag: String?

    private enum CodingKeys: String, CodingKey {
        case method, pathPattern, fixtureName, fixtureKey
        case statusCode, contentType, delayMs, headers
        case requiresFlag, setsFlag
    }

    init(
        method: String? = nil,
        pathPattern: String,
        fixtureName: String,
        fixtureKey: String? = nil,
        statusCode: Int = 200,
        contentType: String = "application/json",
        delayMs: Int? = nil,
        headers: [String: String]? = nil,
        requiresFlag: String? = nil,
        setsFlag: String? = nil
    ) {
        self.method = method
        self.pathPattern = pathPattern
        self.fixtureName = fixtureName
        self.fixtureKey = fixtureKey
        self.statusCode = statusCode
        self.contentType = contentType
        self.delayMs = delayMs
        self.headers = headers
        self.requiresFlag = requiresFlag
        self.setsFlag = setsFlag
    }

    /// Check if this route matches a given URLRequest while `flags` are raised.
    func matches(_ request: URLRequest, flags: Set<String> = []) -> Bool {
        if let requiredFlag = requiresFlag, !flags.contains(requiredFlag) {
            return false
        }

        if let method = method, method.uppercased() != request.httpMethod?.uppercased() {
            return false
        }

        guard let urlString = request.url?.absoluteString else { return false }

        guard let regex = try? NSRegularExpression(pattern: pathPattern, options: .caseInsensitive) else {
            return false
        }

        let range = NSRange(urlString.startIndex..., in: urlString)
        return regex.firstMatch(in: urlString, range: range) != nil
    }
}

#endif
