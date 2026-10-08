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
    private static let generationsByBuild: [String: Int] = [
        "118378": 1,
        "187526": 1,
        "187639": 2,
    ]

    static func generation(forConnectorBuild build: String) -> Int? {
        generationsByBuild[build]
    }
}
