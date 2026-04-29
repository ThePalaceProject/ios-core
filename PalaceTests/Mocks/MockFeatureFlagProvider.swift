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

final class MockFeatureFlagProvider: FeatureFlagProvider {
    var isOPDS2Enabled: Bool

    init(isOPDS2Enabled: Bool = false) {
        self.isOPDS2Enabled = isOPDS2Enabled
    }
}
