//
//  AdobeClientToken.swift
//  Palace
//
//  Adobe short client token parsing, ungated so it compiles into Palace-noDRM
//  (`AdobeDeauthorization` and `AdobeLicensorRefresh` use it from sign-out).
//  PR CI builds only the DRM scheme, so a gated dependency here would not be
//  caught.
//
//  Format, from the CM's `adobe_vendor_id.py`:
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
    /// is empty, so a malformed token is distinguishable from a credential
    /// Adobe rejected (PP-3649).
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
    /// Makes the CM's 60-minute TTL (defined only in `adobe_vendor_id.py`) a
    /// local, testable predicate.
    ///
    /// - Returns: nil when the token cannot be parsed; that is `split`'s
    ///   failure and must not be reported here as staleness.
    static func expiry(_ clientToken: String) -> Date? {
        guard let parts = split(clientToken) else { return nil }
        let fields = parts.username.components(separatedBy: "|")
        guard fields.count >= 2, let seconds = Double(fields[1]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// A description of a client token safe to write to the device log.
    ///
    /// The device log is exportable and attached to support tickets, and these
    /// tokens are live credentials for their 60-minute window. Presence, shape,
    /// minting library and expiry survive; the signature is dropped.
    static func redacted(_ clientToken: String?) -> String {
        guard let clientToken, !clientToken.isEmpty else { return "none" }
        guard let parts = split(clientToken) else {
            return "unparseable (\(clientToken.count) chars, no separator)"
        }
        // Only name the library when the username half has the known 3-field
        // shape; for any other shape the leading field could be the credential.
        let fields = parts.username.components(separatedBy: "|")
        let library = fields.count >= 3 ? (fields.first ?? "?") : "<unexpected \(fields.count + 1)-field token>"
        let expiryText = expiry(clientToken)
            .map(ISO8601DateFormatter().string(from:)) ?? "unreadable"
        return "\(library)|expires \(expiryText)|<redacted \(parts.password.count)-char signature>"
    }
}
