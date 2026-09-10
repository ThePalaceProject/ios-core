//
//  AdobeClientToken.swift
//  Palace
//
//  Everything the app can know about an Adobe short client token WITHOUT the
//  DRM connector.
//
//  WHY THIS EXISTS. `AdobeDeauthorization` and `AdobeLicensorRefresh` are
//  ungated types — `TPPSignInBusinessLogic+ForceReset.swift` calls both and is
//  compiled into `Palace-noDRM` — but they reached for their token parsing
//  through `AdobeDRMService`, which lives inside a whole-file
//  `#if FEATURE_DRM_CONNECTOR` in `AdobeCertificate.swift`. That does not
//  compile in `Palace-noDRM`, and PR CI builds only the DRM scheme
//  (`.github/workflows/non-drm-build.yml` is `on: workflow_dispatch`), so the
//  break would have merged green and landed on the open-source target.
//
//  The fix is placement, not `#if`. A short client token is a STRING FORMAT the
//  Circulation Manager mints; reading it needs no connector, no RMSDK and no
//  ADEPT header. Sprinkling `#if` through the two callers would have left the
//  same knowledge duplicated behind a flag, and every future ungated caller
//  would rediscover the trap. One ungated owner removes the class.
//
//  THE FORMAT, from the CM's `adobe_vendor_id.py`:
//
//      SHORTNAME|expires|patronIdentifier|signature
//      \___________  ____________________/ \___ ___/
//                  \/                          v
//               username                    password
//
//  `expires` is a NumericDate (seconds since the epoch, RFC 7519) written by
//  `_encode_short_client_token` with `expires = {"minutes": 60}`. The final `|`
//  separates the halves Adobe authenticates with; earlier ones belong to the
//  username, which is why the split rejoins everything before the last one.
//

import Foundation

enum AdobeClientToken {

    /// Splits a client token into the `username|password` halves Adobe wants.
    ///
    /// Returns `nil` when the token carries no separator, or when either half
    /// is empty. The old inline split could not express that: for a token with
    /// no "|" it set password to the whole string and username to "", then
    /// handed both to Adobe, which answers `authenticationFailed` — the same
    /// answer it gives for a genuinely rejected credential. Making the
    /// malformed case representable is the point; see PP-3649.
    ///
    /// The username half is rejoined with "|" because a well-formed token
    /// legitimately contains separators before the final one.
    static func split(_ clientToken: String) -> (username: String, password: String)? {
        var items = clientToken
            .replacingOccurrences(of: "\n", with: "")
            .components(separatedBy: "|")
        guard items.count >= 2, let password = items.last, !password.isEmpty else { return nil }
        items.removeLast()
        let username = items.joined(separator: "|")
        guard !username.isEmpty else { return nil }
        return (username, password)
    }

    /// The expiry embedded in a short client token.
    ///
    /// Reading it here is what turns a cross-repository invariant (the CM's
    /// 60-minute TTL, expressed only in `adobe_vendor_id.py`) into a local,
    /// testable predicate.
    ///
    /// - Returns: nil when the token cannot be parsed. An unparseable token is
    ///   a DIFFERENT failure — `split` owns it — and must not be reported here
    ///   as staleness.
    static func expiry(_ clientToken: String) -> Date? {
        guard let parts = split(clientToken) else { return nil }
        let fields = parts.username.components(separatedBy: "|")
        guard fields.count >= 2, let seconds = Double(fields[1]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// A description of a client token safe to write to the device log.
    ///
    /// `Documents/Logs/palace_error.log` is exportable by the patron and gets
    /// attached to support tickets, and these tokens are live credentials for
    /// their 60-minute window. Everything actually used for diagnosis —
    /// is it present, is it the right shape, which library minted it, when
    /// does it die — survives redaction; only the signature is dropped.
    static func redacted(_ clientToken: String?) -> String {
        guard let clientToken, !clientToken.isEmpty else { return "none" }
        guard let parts = split(clientToken) else {
            return "unparseable (\(clientToken.count) chars, no separator)"
        }
        let fields = parts.username.components(separatedBy: "|")
        let library = fields.first ?? "?"
        let expiryText = expiry(clientToken)
            .map(ISO8601DateFormatter().string(from:)) ?? "unreadable"
        return "\(library)|expires \(expiryText)|<redacted \(parts.password.count)-char signature>"
    }
}
