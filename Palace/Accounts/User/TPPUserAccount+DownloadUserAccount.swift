//
//  TPPUserAccount+DownloadUserAccount.swift
//  Palace
//
//  App-side conformance of `TPPUserAccount` to the Downloads-owned
//  `DownloadUserAccount` seam (god-class decomposition Wave 3, S2). This is
//  composition glue: it imports both the concrete account type and the
//  Downloads protocol. At the package split it stays app-target — it is the one
//  place `TPPUserAccount` (→ PalaceAccounts at 3a) and `DownloadUserAccount`
//  (→ PalaceDownloads at 3b) are named together.
//
//  The mirror-enum adapters below are EXHAUSTIVE switches over the real
//  `AccountDetails.Authentication.ReauthStrategy` and `TPPAccountAuthState`, so
//  a new upstream case is a COMPILE error here, not a silent fallthrough (Wave
//  3 §5 risk 3). Do not replace them with a `default:` clause.
//

import Foundation

extension TPPUserAccount: DownloadUserAccount {

    /// Matches the download path's `authDefinition?.isSaml == true` reads —
    /// nil auth definition means "not SAML".
    var isSaml: Bool { authDefinition?.isSaml == true }

    /// Matches the download path's `authDefinition?.isOidc == true` reads.
    var isOidc: Bool { authDefinition?.isOidc == true }

    /// Maps `authDefinition?.reauthStrategy` (defaulting to `.none` when no auth
    /// definition is loaded, exactly as the download path's
    /// `?? .none` reads) through an exhaustive switch.
    var reauthStrategy: DownloadReauthStrategy {
        guard let strategy = authDefinition?.reauthStrategy else { return .none }
        switch strategy {
        case .browser: return .browser
        case .tokenRefresh: return .tokenRefresh
        case .credentialPrompt: return .credentialPrompt
        case .none: return .none
        }
    }

    /// Maps the live `authState` (`TPPAccountAuthState`) through an exhaustive
    /// switch. See the property doc on `DownloadUserAccount.downloadAuthState`
    /// for why this is not named `authState`.
    var downloadAuthState: DownloadAuthState {
        switch authState {
        case .loggedOut: return .loggedOut
        case .loggedIn: return .loggedIn
        case .credentialsStale: return .credentialsStale
        }
    }

    // needsAuth, hasCredentials(), markCredentialsStale(), authToken,
    // setAuthToken(_:barcode:pin:expirationDate:), cookies, setCookies(_:),
    // barcode, PIN, username, userID, deviceID are all already members of
    // TPPUserAccount with matching signatures and satisfy the protocol directly.
}
