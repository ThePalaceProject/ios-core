//
//  AdobeConnectorGeneration.swift
//  Palace
//

import Foundation

/// Which generation of the Adobe DRM connector performed a device activation.
///
/// An activation made by one connector generation is not usable by the next: the
/// Wipro connector reports `E_ACT_NOT_READY` for a device activated under the
/// Adobe-era binaries until the device is activated again (PP-5026). The app
/// therefore records the generation at activation time so it can tell an
/// activation it can use from one it must redo (PP-5251).
///
/// A generation is deliberately coarse. The connector's own `hobbes.build` counter
/// moves on every vendor drop, so keying the decision off it directly would
/// re-trigger the migration on an ordinary patch release.
enum AdobeConnectorGeneration {

    /// The generation of the connector this build links against.
    ///
    /// Raise this only when a drop changes the activation contract, not when the
    /// vendor's build number moves. `AdobeConnectorGenerationTests` ties the value
    /// to a known build number so a drop that moves it fails a test rather than
    /// silently mis-targeting the migration.
    static let current = 1

    /// Known connector builds, as reported by `hobbes.build` in `libhobbes-iOS.a`.
    ///
    /// 118378 shipped from 2021 until `scripts/setup-repo-drm.sh` moved to
    /// `ios-drm-adeptconnector` on 2025-05-21, and 187526 since; both activate
    /// against Adobe's service, so they are one generation. 187639 is Wipro 2.0,
    /// whose service is the break this enum exists for.
    ///
    /// An unmapped build resolves to `nil` on purpose: inferring a generation for
    /// an unknown drop is how a new vendor package would inherit "already
    /// migrated".
    ///
    /// That is a CI-time protection, not a runtime one. This lookup and
    /// `AdobeConnectorBuild.current` have no production call sites; what catches
    /// an unmapped drop is `testCurrentGenerationDescribesTheLinkedConnector`
    /// failing when the linked build stops mapping to `current`.
    private static let generationsByBuild: [String: Int] = [
        "118378": 1,
        "187526": 1,
        "187639": 2,
    ]

    /// The generation an activation carrying no marker was made under.
    ///
    /// Only 118378 (wired 2021-06-10 to 2025-05-21) and 187526 (since) have ever
    /// shipped, and both are generation 1, so an activation that predates the
    /// marker is generation 1 by construction.
    ///
    /// Reading an absent marker as "unknown, therefore re-activate" instead
    /// would move every existing patron's first post-upgrade Adobe borrow off
    /// the fast path and onto the full activation path, which needs a licensor
    /// whose client token expires after 60 minutes. A failed re-mint there
    /// (PP-5025's race, a 401, an expired certificate) fails a borrow that
    /// previously succeeded, on a build where the connector did not change.
    /// Backfilling costs nothing today and still fires the migration for
    /// exactly the affected population once `current` moves past 1.
    static let preMarker = 1

    /// Whether the recorded activation must be redone before the connector this
    /// binary links can use it.
    ///
    /// Pure so the states can be tabled: `AdobeConnectorGenerationTests` walks
    /// every combination rather than only the three the gate happens to reach.
    static func needsReactivation(recorded: Int?, current: Int = current) -> Bool {
        (recorded ?? preMarker) != current
    }

    static func generation(forConnectorBuild build: String) -> Int? {
        generationsByBuild[build]
    }
}
