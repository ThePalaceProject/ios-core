//
//  AdobeDeauthorization.swift
//  Palace
//
//  The two decisions the sign-out deauthorization path makes, separated from
//  the sign-out machinery so they can be asserted.
//
//  WHY THIS EXISTS. Signing out is the only thing in the app that returns an
//  Adobe activation slot — there is no device-management screen, and nothing
//  else calls `deauthorize`. So when this path fails, the slot is gone until
//  the patron's Adobe identity is reset server-side, and the next sign-in
//  spends another one. A patron who signs in and out a few times over a slow
//  connection can reach `E_ACT_TOO_MANY_ACTIVATIONS` without ever doing
//  anything unusual.
//
//  Two things made that invisible:
//
//  1. The client token is split inline, and the split cannot fail — a token
//     with no `|` yielded an empty username and the whole token as the
//     password, which was then sent to Adobe as if it were real.
//  2. Every failure was logged as `warn` with the word "(expected)", on the
//     grounds that `E_DEACT_USER_MISMATCH` happens when a patron changes their
//     PIN. That reasoning is right about the cause and wrong about the
//     consequence: the slot is still consumed. A leaked activation and a
//     harmless one produced identical output.
//

import Foundation
import PalaceLogging

enum AdobeDeauthorization {

    /// Everything Adobe needs to release a (user, device) pair.
    ///
    /// `userID` and `deviceID` are optional deliberately. An earlier version of
    /// this required both to be non-empty, on the reasoning that Adobe releases
    /// a (user, device) pair and neither half can be missing. That reasoning is
    /// plausible and unverifiable here: `NYPLADEPT` ships as a binary, so what
    /// `deauthorizeWithUsername:password:userID:deviceID:` does with a nil
    /// userID — fail, or resolve it from the local activation — cannot be read
    /// from this repo. Its header declares username and password
    /// `NSString *const` and these two plain nullable `NSString*`, which is a
    /// hint in the other direction.
    ///
    /// Refusing on an unverifiable precondition is the worse error here: a
    /// patron holding a licensor but no stored deviceID would skip
    /// deauthorization ENTIRELY and leak the activation, which is the defect
    /// this type exists to fix. So the guard covers only what is provable — a
    /// client token that cannot be split cannot authenticate anything — and the
    /// (user, device) pair is passed through exactly as the previous code did.
    /// `TPPIdleSignOutRegressionTests` exercises precisely that case.
    struct Attempt: Equatable {
        let username: String
        let password: String
        let userID: String?
        let deviceID: String?
    }

    /// - Returns: nil when the call cannot possibly free anything, so the
    ///   caller can say so rather than spend a round trip and read the
    ///   inevitable failure as bad luck.
    static func attempt(licensor: [String: Any]?,
                        userID: String?,
                        deviceID: String?) -> Attempt? {
        guard let clientToken = licensor?["clientToken"] as? String,
              let parts = AdobeDRMService.splitClientToken(clientToken)
        else { return nil }

        return Attempt(username: parts.username,
                       password: parts.password,
                       userID: userID,
                       deviceID: deviceID)
    }

    /// What the deauthorization did to the patron's activation count.
    ///
    /// There is deliberately no `benign` case. Whatever the reason, a
    /// deauthorization that did not succeed leaves the slot consumed, and
    /// naming that outcome anything softer is what hid this for two years.
    enum Outcome: Equatable {
        case freed
        case notFreed(reason: String)
    }

    static func outcome(success: Bool, error: Error?) -> Outcome {
        guard !success else { return .freed }

        guard let error else {
            return .notFreed(reason: "Adobe reported failure with no error")
        }

        let ns = error as NSError
        if let originalCode = ns.userInfo[NYPLADEPTErrorOriginalCodeKey] as? String {
            return .notFreed(reason: originalCode)
        }
        return .notFreed(reason: "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
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
        guard let parts = AdobeDRMService.splitClientToken(clientToken) else {
            return "unparseable (\(clientToken.count) chars, no separator)"
        }
        let fields = parts.username.components(separatedBy: "|")
        let library = fields.first ?? "?"
        let expiry = AdobeLicensorRefresh.clientTokenExpiry(clientToken)
            .map(ISO8601DateFormatter().string(from:)) ?? "unreadable"
        return "\(library)|expires \(expiry)|<redacted \(parts.password.count)-char signature>"
    }
}
