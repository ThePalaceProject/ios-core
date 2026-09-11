//
//  AdobeLicensorRefresh.swift
//  Palace
//
//  Re-mints the Adobe licensor immediately before device activation.
//
//  WHY THIS EXISTS (PP-3649). The Circulation Manager's short client token
//  carries a 60-minute expiry and the CM enforces it:
//
//      expires = {"minutes": 60}                       # encode_short_client_token
//      if expiration_datetime < now: raise ValueError  # _decode_short_client_token
//
//  The token is written to the keychain once, on the user-profile-document leg
//  of sign-in, by `TPPUserAccount.setLicensor` — the only place it is ever
//  written. PP-3649 then moved Adobe activation OFF sign-in and onto the first
//  Adobe borrow, which can be arbitrarily later. Past the hour, Adobe rejects
//  the stale token as `E_<vendor>_AUTH  Incorrect barcode or PIN` — a message
//  that reads like bad patron credentials and is nothing of the kind.
//
//  Measured on device 2026-09-09: activation failed 555ms after the borrow
//  began, against a 15s licensor grace period — i.e. the credential was
//  present and simply old. Crashlytics: 25,421 events / 4,013 users, first
//  seen in 3.0.0, the version that shipped the deferral.
//
//  Android does not have this bug because `BorrowACSM.adobeDeviceActivate`
//  re-runs the patron profile request and activates with the token it just
//  received. This is the iOS equivalent of that step.
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
    /// Deliberately returns FALSE when the expiry cannot be read. Manufacturing
    /// staleness from an unparseable token would mask the real defect behind a
    /// refresh, and the refresh happens regardless — this predicate exists so
    /// the condition is assertable in a test and nameable in a log, not to
    /// gate behaviour.
    static func isExpired(_ licensor: [String: Any]?, now: Date = Date()) -> Bool {
        guard let clientToken = licensor?["clientToken"] as? String,
              let expiry = AdobeClientToken.expiry(clientToken) else { return false }
        return expiry < now
    }

    /// Chooses the licensor to activate with, preferring a freshly minted one.
    ///
    /// Falls back to `stored` when the fetch yields nothing usable — offline,
    /// a server error, or a library with no Adobe DRM. That is deliberate: a
    /// stored token may still be inside its hour, and failing the borrow
    /// outright because a refresh could not be reached would turn a
    /// working case into a broken one.
    ///
    /// - Returns: the licensor to use, and whether it came from the fetch
    ///   (the caller persists only in that case — writing back a value that
    ///   came from the keychain would be a pointless keychain write).
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
        // Unconditional, and the `if stored != nil` that used to wrap it is gone
        // deliberately. It gated nothing but the wording of a log line, so no
        // test could ever justify it — mutation confirmed exactly that, flipping
        // it to `== nil` with the whole suite green. A predicate with no
        // behaviour is not coverage worth buying with a coverage-only test; it
        // is a distinction to delete. The absent-stored case is unambiguous in
        // the log regardless: `ensureDeviceActivated`'s next line is
        // "No Adobe DRM licensor credentials stored — cannot activate", at error
        // level.
        Log.info(#file, "Licensor refresh yielded nothing usable — falling back to the stored licensor")
        return (stored, false)
    }
}
