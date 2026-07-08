//
//  LoanEvictionPolicy.swift
//  Palace
//
//  Reliability WS-C — seam S3. The single guardrail behind INV-2:
//  "Never delete a downloaded file while offline based on a cached
//  `until` alone."
//
//  Pure, no I/O. `MyBooksViewModel` calls `decide(...)` for every
//  expired-by-cached-`until` book and only deletes local content +
//  unregisters on `.evict`. Offline-expired books resolve to `.keep`
//  so the patron's downloaded file survives; online-but-within-grace
//  resolves to `.confirmWithServer` (keep locally, let the loans-feed
//  sync reconcile) rather than destroying the file on a possibly-stale
//  `until` / clock-skewed date.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The eviction decision for a single downloaded loan.
enum EvictionDecision: Equatable {
    /// Keep the file and the registry record. The book stays openable.
    case keep
    /// Delete local content and unregister — the loan is provably over.
    case evict
    /// Keep locally for now, but the loan *may* be over; a server sync
    /// (loans feed) should confirm before any deletion. Never destroys
    /// the file on its own.
    case confirmWithServer
}

/// Pure eviction-decision function. See INV-2.
enum LoanEvictionPolicy {

    /// Default grace window applied after a loan's `until` before an
    /// online device is willing to evict without an explicit loans-feed
    /// round trip. Covers modest clock skew between client and server.
    static let defaultGrace: TimeInterval = 5 * 60 // 5 minutes

    /// Decide whether a downloaded loan may be evicted.
    ///
    /// - Parameters:
    ///   - expiration: the cached loan `until` date (`TPPBook.getExpirationDate()`).
    ///     `nil` means no expiry is known — never evict.
    ///   - now: the current time (injected for determinism).
    ///   - isOnline: whether the device currently has connectivity.
    ///   - grace: the post-`until` window during which an online device
    ///     still defers to a server confirmation rather than evicting.
    /// - Returns: `.keep`, `.evict`, or `.confirmWithServer`.
    ///
    /// Decision matrix (INV-2):
    ///   - no expiration            -> `.keep`
    ///   - not yet expired          -> `.keep`
    ///   - expired + offline        -> `.keep`   (never delete offline on cached `until`)
    ///   - expired + online, within grace -> `.confirmWithServer`
    ///   - expired + online, past grace   -> `.evict`
    static func decide(
        expiration: Date?,
        now: Date,
        isOnline: Bool,
        grace: TimeInterval = defaultGrace
    ) -> EvictionDecision {
        // No expiry information -> nothing to evict on.
        guard let expiration else { return .keep }

        // Not yet expired (by the cached date) -> keep.
        if now < expiration { return .keep }

        // Expired by the cached `until`. Offline is the INV-2 guard: a
        // stale/early `until`, clock skew, or a server that would still
        // honor the loan must NOT cost the patron their downloaded file.
        guard isOnline else { return .keep }

        // Online + past `until` + grace -> the loan is provably over.
        if now >= expiration.addingTimeInterval(grace) {
            return .evict
        }

        // Online + within grace -> defer to a server confirmation.
        return .confirmWithServer
    }
}
