//
//  OPDSFeedFetching.swift
//  PalaceCatalog
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Narrow protocol that `BookRegistrySync`, `BookReturnService`, and similar
/// callers depend on so tests can substitute a fixture / failing fetcher without
/// standing up the full actor + URL stack. Production code passes an
/// `OPDSFeedService` instance that satisfies this protocol via its conformance.
///
/// Relocated to PalaceCatalog (god-class decomposition Wave 2b) so it sits beside
/// the `TPPOPDSFeed` it returns — this lets the PalaceBookRegistry package depend
/// on the feed-fetch seam without an edge back into the app target. `OPDSFeedService`
/// (the live actor) stays app-side and conforms across the package boundary.
public protocol OPDSFeedFetching: Sendable {
    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed
    /// Cache-control-aware form. `BookRegistrySync`'s loans sync passes
    /// `resetCache: true` so a stale cached loans feed can't mask a return /
    /// borrow that happened on another device. Defaulted in the extension
    /// below so existing fixture fetchers that only distinguish by URL keep
    /// conforming unchanged.
    func fetchFeed(from url: URL, resetCache: Bool) async throws -> TPPOPDSFeed
}

public extension OPDSFeedFetching {
    /// Conformers that don't model cache semantics (test fakes, the
    /// return-flow revoke fetcher) fall back to the plain URL fetch — the
    /// `resetCache` distinction only matters for the live actor witness.
    func fetchFeed(from url: URL, resetCache: Bool) async throws -> TPPOPDSFeed {
        try await fetchFeed(from: url)
    }
}
