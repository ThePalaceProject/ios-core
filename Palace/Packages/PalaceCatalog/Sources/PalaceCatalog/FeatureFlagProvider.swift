import Foundation

/// Boundary for feature-flag reads inside PalaceCatalog.
///
/// The package never reads `RemoteFeatureFlags.shared` directly. Callers in
/// the app target wire up a conforming type at composition time (today
/// `RemoteFeatureFlags` itself, via an empty conformance extension).
///
/// The protocol intentionally exposes only the flags PalaceCatalog reads.
/// Adding an unrelated flag here is a smell — extend the protocol only when
/// the package actually needs the flag.
public protocol FeatureFlagProvider: AnyObject {
    /// True when the OPDS 2 catalog format is enabled. Controls the
    /// `Accept` header sent by `DefaultCatalogAPI.fetchFeed(at:)` —
    /// when enabled, OPDS 2 (`application/opds+json`) is preferred over
    /// OPDS 1 (`application/atom+xml`).
    var isOPDS2Enabled: Bool { get }
}
