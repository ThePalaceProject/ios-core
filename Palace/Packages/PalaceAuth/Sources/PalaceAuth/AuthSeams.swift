//
//  AuthSeams.swift
//  PalaceAuth
//
//  Public protocol seams that decouple PalaceAuth from main-target types.
//  Conformances live in the main target via single-purpose extension files.
//
//  Sized per recon: Account = 1 read + 6 writes, AccountDetails = 4 reads.
//  This impl ships the slim slice that supports the files actually moved
//  in this PR (impl 1's TPPSAMLHelper / TPPUserAccountFrontEndValidation,
//  plus this impl's seam shims). Future SignInLogic moves may grow this.
//
//  **Protocol-gravity-inversion (recon Risk 4) was scoped OUT of this impl.**
//  Moving `TPPCurrentLibraryAccountProvider`, `TPPUserAccountResolving`,
//  `TPPLibraryAccountsProvider`, `TPPSignedInStateProvider`,
//  `TPPUserAccountProvider`, `NYPLUniversalLinksSettings`, and
//  `NYPLFeedURLProvider` into PalaceAuth would require also moving the
//  `Account` / `AccountDetails` / `TPPUserAccount` / `TPPSettings` slice
//  shapes (and rewriting every callsite that takes the concrete return types
//  to take the seam types instead). That cascade is the integrator's scope.
//  See transcript section "Deferred work for integrator" for the full audit.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Library account read-only slice (Accommodation 1 in contract)

/// Narrow read-only slice of the main-target `Account` class.
/// Extends impl 1's stub of `uuid: String` with the `hasUpdatedToken`
/// setter that Sign Out + Reset Account toggle.
///
/// Main target conforms `Account` to this in
/// `Account+TPPLibraryAccountReadable.swift` (impl 4 wires).
///
/// **Growth boundary**: every property here is forced public surface, so
/// only add what code in this package actually reads.
public protocol TPPLibraryAccountReadable: AnyObject {
    /// Stable identifier for the library account.
    var uuid: String { get }

    /// True after FCM push token registration succeeded for this account.
    /// Sign Out + Reset Account toggle this off before deregistering the
    /// CM-side token. Setter exposed because both flows write it.
    var hasUpdatedToken: Bool { get set }
}

/// Slice of `AccountDetails` exposed to PalaceAuth. Recon found 4 reads
/// (`auths`, `userProfileUrl`, `signUpUrl`, `getLicenseURL()`). Three are
/// exposed here; `auths` is left to the integrator who decides whether to
/// expose `[any TPPAuthenticationDescribing]` or some richer alternative
/// when the rest of SignInLogic moves into the package.
public protocol TPPAuthenticationDocumentReadable: AnyObject {
    /// HTTP URL string for the user-profile endpoint.
    var userProfileUrl: String? { get }

    /// Card-creator URL when the library supports patron self-registration.
    var signUpUrl: URL? { get }

    /// True when the library supports SimplyE annotation sync (used by
    /// `shouldShowSyncButton` once it moves into the package).
    var supportsSimplyESync: Bool { get }
}

// MARK: - Push token deleter

/// Deregisters the FCM push token for an account. Sign Out + Reset Account
/// both call this before clearing credentials. Main-target
/// `NotificationService` conforms via a 3-line extension at
/// `Palace/AppInfrastructure/NotificationService+PushTokenDeleting.swift`
/// (impl 4 wires).
public protocol PushTokenDeleting: AnyObject {
    /// Best-effort DELETE of the patron's FCM token from the CM. Fire-and-
    /// forget — Sign Out and Reset Account both proceed even if this fails.
    func deletePushToken(for libraryAccount: TPPLibraryAccountReadable)
}
