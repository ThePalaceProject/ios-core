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
//  This type is UNGATED on purpose — `TPPSignInBusinessLogic+ForceReset.swift`
//  calls it and is compiled into `Palace-noDRM`. Everything it needs about a
//  client token lives in `AdobeClientToken`, which has no DRM dependency for
//  the same reason.
//

import Foundation
import PalaceLogging

enum AdobeDeauthorization {

    /// Everything Adobe needs to release a (user, device) pair, plus whether
    /// this attempt can actually do that.
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
    /// this type exists to fix. So the guard covers only what is provable, and
    /// the (user, device) pair is passed through exactly as the previous code
    /// did. `TPPIdleSignOutRegressionTests` exercises precisely that case.
    struct Attempt: Equatable {
        let username: String
        let password: String
        let userID: String?
        let deviceID: String?

        /// Whether the credentials in this attempt can authenticate to Adobe at
        /// all — i.e. whether the SERVER-side slot has any chance of coming
        /// back. False means the call is worth making for its LOCAL effect only
        /// (see `attempt(licensor:userID:deviceID:)`), and the caller should say
        /// so in the log rather than read the inevitable failure as bad luck.
        let canReleaseServerSlot: Bool
    }

    /// - Returns: nil only when there is no Adobe state at all to act on. A
    ///   licensor whose client token cannot be split still yields an attempt,
    ///   with `canReleaseServerSlot == false`.
    ///
    ///   An earlier version of this returned nil for the unparseable token too,
    ///   and that was the same unverifiable-precondition mistake corrected
    ///   above, made on the other half. `deauthorize` has TWO effects: it asks
    ///   Adobe to release the slot, and RMSDK clears the LOCAL activation files
    ///   regardless of what the network says. The local clear is what lets the
    ///   next sign-in re-activate cleanly, and it is the entire reason Reset
    ///   Account calls this at all — so refusing to call on a malformed token
    ///   withheld the repair from exactly the patron who needed it: one who HAS
    ///   activated and whose stored token has gone bad. `develop` called
    ///   `deauthorize` whenever a licensor existed; this restores that bar and
    ///   keeps the diagnosis the branch added.
    static func attempt(licensor: [String: Any]?,
                        userID: String?,
                        deviceID: String?) -> Attempt? {
        guard let licensor else { return nil }

        let parts = (licensor["clientToken"] as? String).flatMap(AdobeClientToken.split)
        return Attempt(username: parts?.username ?? "",
                       password: parts?.password ?? "",
                       userID: userID,
                       deviceID: deviceID,
                       canReleaseServerSlot: parts != nil)
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

    /// The `NSError.userInfo` key under which ADEPT stashes Adobe's own error
    /// code.
    ///
    /// Spelled out rather than referencing `NYPLADEPTErrorOriginalCodeKey`
    /// because this type compiles into `Palace-noDRM`, where the ADEPT headers
    /// are absent. `AdobeDeauthorizationTests` asserts (under
    /// `#if FEATURE_DRM_CONNECTOR`) that the two strings are equal, so the
    /// literal cannot silently drift from the header it mirrors.
    static let adobeOriginalCodeKey = "originalCode"

    static func outcome(success: Bool, error: Error?) -> Outcome {
        guard !success else { return .freed }

        guard let error else {
            return .notFreed(reason: "Adobe reported failure with no error")
        }

        let ns = error as NSError
        if let originalCode = ns.userInfo[adobeOriginalCodeKey] as? String {
            return .notFreed(reason: originalCode)
        }
        return .notFreed(reason: "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }
}
