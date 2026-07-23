//
//  TPPSettingsAuthBridge.swift
//  Palace
//
//  Wave 1a (PalacePreferences): app-target bridge that re-attaches the
//  auth-flow protocol conformances TPPSettings carried before it moved into
//  the PalacePreferences package. The @objc protocols stay app-target because
//  their only consumers (TPPSignInBusinessLogic, LegacySAMLAuthAdapter) are
//  app-target; the package must stay dependency-free.
//

import Foundation
import PalaceAuth
import PalacePreferences

@objc protocol NYPLUniversalLinksSettings: NSObjectProtocol {
    /// The URL that will be used to redirect an external authentication flow
    /// back to the our app. This URL will need to be provided to the external
    /// service. For example, Clever authentication uses this URL to redirect
    /// to the app after authenticating in Safari.
    var universalLinksURL: URL { get }
}

@objc protocol NYPLFeedURLProvider {
    var accountMainFeedURL: URL? { get set }
}

extension TPPSettings: NYPLUniversalLinksSettings {
    /// Used to handle Clever and SAML sign-ins in SimplyE.
    @objc var universalLinksURL: URL {
        URL(string: "https://librarysimplified.org/callbacks/SimplyE")!
    }
}

extension TPPSettings: NYPLFeedURLProvider {}

// PalaceAuth's TPPSAMLHelper consumes the callback URL via this protocol.
// @retroactive: both TPPSettings (PalacePreferences) and the protocol
// (PalaceAuth) are imported; the conformance is deliberate app-level glue.
extension TPPSettings: @retroactive UniversalLinksProviding {}
