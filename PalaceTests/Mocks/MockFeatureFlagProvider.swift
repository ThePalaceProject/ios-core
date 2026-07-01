//
//  MockFeatureFlagProvider.swift
//  PalaceTests
//
//  Test double for PalaceCatalog's FeatureFlagProvider seam. Lets tests
//  control which feature-flag branches DefaultCatalogAPI exercises
//  without reaching for RemoteFeatureFlags.shared.
//

import Foundation
import PalaceCatalog

/// Test double whose single mutable flag is set once during arrange and read
/// on the test's serial flow; `@unchecked Sendable` documents that confinement
/// (the inherited `FeatureFlagProvider: Sendable` requirement forbids a plain
/// mutable `var` otherwise).
final class MockFeatureFlagProvider: FeatureFlagProvider, @unchecked Sendable {
    var isOPDS2Enabled: Bool

    init(isOPDS2Enabled: Bool = false) {
        self.isOPDS2Enabled = isOPDS2Enabled
    }
}
