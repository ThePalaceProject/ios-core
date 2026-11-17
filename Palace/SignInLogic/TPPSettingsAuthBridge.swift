//
//  TPPSettingsAuthBridge.swift
//  Palace
//
//  App-target auth-flow protocol conformances for TPPSettings, which lives in
//  the PalacePreferences package. The protocols are plain Swift, so these
//  conformances add no ObjC category and the package stays dependency-free.
//

import Foundation
import PalaceAuth
import PalacePreferences

protocol NYPLUniversalLinksSettings: AnyObject {
    /// The URL that will be used to redirect an external authentication flow
    /// back to the our app. This URL will need to be provided to the external
    /// service. For example, Clever authentication uses this URL to redirect
    /// to the app after authenticating in Safari.
    var universalLinksURL: URL { get }
}

protocol NYPLFeedURLProvider: AnyObject {
    var accountMainFeedURL: URL? { get set }
}

extension TPPSettings: NYPLUniversalLinksSettings {
    /// Used to handle Clever and SAML sign-ins in SimplyE.
    // `public` because this property is the witness for PalaceAuth's PUBLIC
    // `UniversalLinksProviding` requirement (conformed below) — a public-protocol
    // witness must be public even though NYPLUniversalLinksSettings is app-internal.
    public var universalLinksURL: URL {
        URL(string: "https://librarysimplified.org/callbacks/SimplyE")!
    }
}

extension TPPSettings: NYPLFeedURLProvider {}

// PalaceAuth's TPPSAMLHelper consumes the callback URL via this protocol.
// @retroactive: both TPPSettings (PalacePreferences) and the protocol
// (PalaceAuth) are imported; the conformance is deliberate app-level glue.
extension TPPSettings: @retroactive UniversalLinksProviding {}
