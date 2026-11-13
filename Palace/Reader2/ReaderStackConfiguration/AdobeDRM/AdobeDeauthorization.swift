//
//  AdobeDeauthorization.swift
//  Palace
//
//  The two decisions the sign-out deauthorization path makes, separated so
//  they can be asserted. Sign-out is the only path that returns an Adobe
//  activation slot, so a failed deauthorization consumes one until the
//  patron's Adobe identity is reset server-side; repeated sign-ins can reach
//  `E_ACT_TOO_MANY_ACTIVATIONS`. Every non-success is therefore reported as a
//  leaked slot, and an unsplittable client token is diagnosed explicitly.
//  Ungated because `TPPSignInBusinessLogic+ForceReset.swift` compiles into
//  Palace-noDRM.
//

import Foundation
import PalaceLogging

enum AdobeDeauthorization {

    /// Everything Adobe needs to release a (user, device) pair, plus whether
    /// this attempt can actually do that.
    ///
    /// `userID` and `deviceID` are optional deliberately. `NYPLADEPT` ships as a
    /// binary, so how `deauthorizeWithUsername:password:userID:deviceID:`
    /// treats a nil userID cannot be verified here (its header declares both
    /// nullable). Requiring them would skip deauthorization entirely for a
    /// patron with no stored deviceID and leak the activation, so they are
    /// passed through as-is (see `TPPIdleSignOutRegressionTests`).
    struct Attempt: Equatable {
        let username: String
        let password: String
        let userID: String?
        let deviceID: String?

        /// Whether the credentials in this attempt can authenticate to Adobe at
        /// all, i.e. whether the server-side slot can come back. False means the
        /// call is made for its local effect only, and the caller logs that.
        let canReleaseServerSlot: Bool
    }

    /// - Returns: nil only when there is no Adobe state at all to act on. A
    ///   licensor whose client token cannot be split still yields an attempt,
    ///   with `canReleaseServerSlot == false`.
    ///
    ///   `deauthorize` has two effects: it asks Adobe to release the slot, and
    ///   RMSDK clears the local activation files regardless of the network
    ///   result. The local clear lets the next sign-in re-activate cleanly and
    ///   is why Reset Account calls this, so a malformed token must not skip it.
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
    /// There is deliberately no `benign` case: whatever the reason, a
    /// deauthorization that did not succeed leaves the slot consumed.
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
    /// `#if FEATURE_DRM_CONNECTOR`) that the two strings are equal.
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
