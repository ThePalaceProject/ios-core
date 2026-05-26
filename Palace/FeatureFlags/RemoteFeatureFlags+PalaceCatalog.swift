import Foundation
import PalaceCatalog

/// Conformance bridge so PalaceCatalog can read feature flags via its
/// `FeatureFlagProvider` protocol seam. The package never imports
/// FirebaseCore or RemoteFeatureFlags directly — this empty extension
/// is the only piece that wires the two together.
extension RemoteFeatureFlags: FeatureFlagProvider {}
