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
/// Lives beside `TPPOPDSFeed` so PalaceBookRegistry can depend on it without an
/// edge into the app target, where `OPDSFeedService` conforms.
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
