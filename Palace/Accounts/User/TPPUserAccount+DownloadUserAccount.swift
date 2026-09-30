//
//  TPPUserAccount+DownloadUserAccount.swift
//  Palace
//
//  App-side conformance of `TPPUserAccount` to the Downloads-owned
//  `DownloadUserAccount` protocol: the one place the two types are named together.
//
//  The mirror-enum adapters below are exhaustive switches, so a new upstream
//  case is a compile error here rather than a fallthrough. Do not add `default:`.
//

import Foundation

extension TPPUserAccount: DownloadUserAccount {

    /// A nil auth definition means "not SAML".
    var isSaml: Bool { authDefinition?.isSaml == true }

    var isOidc: Bool { authDefinition?.isOidc == true }

    /// `.none` when no auth definition is loaded.
    var reauthStrategy: DownloadReauthStrategy {
        guard let strategy = authDefinition?.reauthStrategy else { return .none }
        switch strategy {
        case .browser: return .browser
        case .tokenRefresh: return .tokenRefresh
        case .credentialPrompt: return .credentialPrompt
        case .none: return .none
        }
    }

    /// See `DownloadUserAccount.downloadAuthState` for why this is not named `authState`.
    var downloadAuthState: DownloadAuthState {
        switch authState {
        case .loggedOut: return .loggedOut
        case .loggedIn: return .loggedIn
        case .credentialsStale: return .credentialsStale
        }
    }

    // The remaining requirements are existing TPPUserAccount members.
}
