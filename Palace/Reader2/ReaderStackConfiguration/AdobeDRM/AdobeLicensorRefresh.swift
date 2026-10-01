//
//  AdobeLicensorRefresh.swift
//  Palace
//
//  Re-mints the Adobe licensor immediately before device activation (PP-3649).
//  The CM's short client token expires after 60 minutes, but it is stored once
//  at sign-in and activation happens at the first Adobe borrow, which can be
//  much later. Adobe rejects a stale token as "Incorrect barcode or PIN". This
//  mirrors Android's `BorrowACSM.adobeDeviceActivate`, which re-fetches the
//  patron profile before activating.
//

import Foundation
import PalaceLogging

enum AdobeLicensorRefresh {

    /// A licensor is only worth activating with if it carries both halves
    /// Adobe needs. Mirrors the guard in `ensureDeviceActivated`, so a
    /// refreshed-but-empty document cannot displace a usable stored one.
    static func isUsable(_ licensor: [String: Any]?) -> Bool {
        guard let licensor else { return false }
        guard let vendor = licensor["vendor"] as? String, !vendor.isEmpty else { return false }
        guard let clientToken = licensor["clientToken"] as? String, !clientToken.isEmpty else { return false }
        return true
    }

    /// Whether the licensor's token is already past its expiry.
    ///
    /// Returns false when the expiry cannot be read, so a malformed token is
    /// not reported as stale. Used for logging and tests; it does not gate the
    /// refresh.
    static func isExpired(_ licensor: [String: Any]?, now: Date = Date()) -> Bool {
        guard let clientToken = licensor?["clientToken"] as? String,
              let expiry = AdobeClientToken.expiry(clientToken) else { return false }
        return expiry < now
    }

    /// Chooses the licensor to activate with, preferring a freshly minted one.
    ///
    /// Falls back to `stored` when the fetch yields nothing usable — offline,
    /// a server error, or a library with no Adobe DRM: a stored token may still
    /// be inside its hour.
    ///
    /// - Returns: the licensor to use, and whether it came from the fetch
    ///   (the caller persists only in that case).
    static func resolve(
        stored: [String: Any]?,
        fetch: () async -> [String: Any]?
    ) async -> (licensor: [String: Any]?, wasRefreshed: Bool) {
        if isExpired(stored) {
            // The line that would have named PP-3649 in one reading.
            Log.info(#file, "Stored Adobe licensor is past its expiry — refreshing before activation")
        }

        let fetched = await fetch()
        if isUsable(fetched) {
            Log.info(#file, "Refreshed Adobe licensor before activation")
            return (fetched, true)
        }
        if isExpired(stored) {
            Log.error(#file, "Refresh failed and the stored Adobe licensor is EXPIRED — activation will be rejected as bad credentials (PP-3649)")
        }
        // Logged unconditionally; when nothing is stored, `ensureDeviceActivated`
        // logs that at error level next.
        Log.info(#file, "Licensor refresh yielded nothing usable — falling back to the stored licensor")
        return (stored, false)
    }
}
