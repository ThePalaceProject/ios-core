//
//  ManifestFixture.swift
//
//  Loads audiobook manifest fixtures owned by this repository. They used to
//  come from the toolkit's `ManifestJSON` test helper via `@testable import`,
//  which ios-audiobooktoolkit#205 moved to the toolkit's test target. To add a
//  case: put the `.json` in `PalaceTests/`, add it to the PalaceTests Copy
//  Bundle Resources phase, then add the case; `testEveryManifestFixtureIsBundled`
//  fails if the JSON is not bundled.
//

import Foundation
import XCTest

@testable import PalaceAudiobookToolkit

extension Manifest {
    /// Decode a manifest fixture bundled with the test target.
    ///
    /// Uses the toolkit's `customDecoder()` so fixtures decode exactly as
    /// production manifests do -- a plain `JSONDecoder` would silently diverge
    /// on the date and context strategies and make these tests lie.
    static func from(jsonFileName: String, bundle: Bundle = .main) throws -> Manifest {
        guard let url = bundle.url(forResource: jsonFileName, withExtension: "json") else {
            throw ManifestFixtureError.notBundled(name: jsonFileName, bundle: bundle.bundleIdentifier ?? "?")
        }
        let data = try Data(contentsOf: url)
        return try Manifest.customDecoder().decode(Manifest.self, from: data)
    }
}

enum ManifestFixtureError: Error, CustomStringConvertible {
    case notBundled(name: String, bundle: String)

    var description: String {
        switch self {
        case let .notBundled(name, bundle):
            return "\(name).json is not in bundle \(bundle). Add it to PalaceTests/ AND to the "
                + "PalaceTests target's Copy Bundle Resources phase — being in the folder is not enough."
        }
    }
}

/// The manifest fixtures this repository ships. Deliberately a short list: it
/// mirrors `PalaceTests/*.json`, not the toolkit's much longer catalogue.
enum ManifestJSON: String, CaseIterable {
    case snowcrash = "snowcrash_manifest"
    case duneOversubdivided = "dune_oversubdivided_manifest"
}

/// Guards the fixture set itself. Without this, adding a case whose JSON is not
/// bundled fails later, somewhere else, as an opaque decode or unwrap error in
/// whichever test happens to use it first.
final class ManifestFixtureTests: XCTestCase {

    func testEveryManifestFixtureIsBundled() throws {
        let bundle = Bundle(for: type(of: self))
        for fixture in ManifestJSON.allCases {
            XCTAssertNoThrow(
                try Manifest.from(jsonFileName: fixture.rawValue, bundle: bundle),
                "\(fixture.rawValue).json is declared in ManifestJSON but does not decode from the "
                    + "test bundle. Either the file is missing, not in Copy Bundle Resources, or no "
                    + "longer parses with the toolkit's customDecoder()."
            )
        }
    }

    /// Non-vacuity: if `allCases` were ever empty the loop above would pass
    /// while checking nothing.
    func testFixtureSetIsNotEmpty() {
        XCTAssertFalse(
            ManifestJSON.allCases.isEmpty,
            "ManifestJSON has no cases, so testEveryManifestFixtureIsBundled asserts nothing."
        )
    }
}
