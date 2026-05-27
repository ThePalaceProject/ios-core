//
//  AccountsManager+TPPCurrentLibraryAccountProviding.swift
//  Palace
//
//  Bridges `AccountsManager` to PalaceAuth's
//  `TPPCurrentLibraryAccountProviding` protocol so the `AuthCoordinator`
//  can resolve the active library's auth mechanism at dispatch time
//  without importing main-target types.
//
//  Implemented as a thin adapter (not a direct extension) so we can
//  expose only the slim `currentAccountMechanism: AuthMechanism?`
//  property the coordinator needs — the full Account / AccountDetails
//  surface is NOT promoted to PalaceAuth (Phase 3 trunk-move scope).
//
//  Module C of swarm_66819d80.
//

import Foundation
import PalaceAuth
import PalaceCatalog

/// Adapter that exposes only the active library's `AuthMechanism` to the
/// coordinator. Resolves through `AccountsManager` on every read so
/// library swaps mid-flow are observed without restarting the coordinator.
final class CoordinatorAccountProvider: TPPCurrentLibraryAccountProviding {

    private let accountsManager: AccountsManager

    init(accountsManager: AccountsManager) {
        self.accountsManager = accountsManager
    }

    var currentAccountMechanism: AuthMechanism? {
        guard let authType = accountsManager.currentAccount?.details?.defaultAuth?.authType else {
            return nil
        }
        return Self.map(authType: authType)
    }

    /// Maps `AccountDetails.AuthType` → PalaceAuth `AuthMechanism`.
    /// `.coppa`, `.anonymous`, and `.none` collapse to nil — those library
    /// flavors don't have a coordinator-driven re-auth surface, so the
    /// coordinator returns `.noActiveAccount` and the caller falls back to
    /// its legacy path (typically a no-op because there's no auth to
    /// refresh).
    static func map(authType: AccountDetails.AuthType) -> AuthMechanism? {
        switch authType {
        case .basic:              return .basic
        case .token:              return .token
        case .oauthIntermediary:  return .oauthIntermediary
        case .saml:               return .saml
        case .oidc:               return .oidc
        case .coppa, .anonymous, .none:
            return nil
        }
    }
}
