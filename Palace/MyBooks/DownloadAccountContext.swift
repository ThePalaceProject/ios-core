//
//  DownloadAccountContext.swift
//  Palace
//
//  Downloads-owned account-context protocols. They invert the Downloads→Accounts
//  read coupling without widening PalaceBookRegistry's `AccountScopeProviding`,
//  which must not carry download-auth capability. The surface is deliberately
//  narrow: value queries (`needsAuth`/`isSaml`/`isOidc`/`reauthStrategy`) plus
//  the 401-recovery writeback. `Account`, `AccountsManager`, `TPPUserAccount`
//  and the `authDefinition` object never cross, so these can move into a
//  package without moving `TPPUserAccount`. See
//  docs/architecture/god-class-decomposition-plan.md.
//

import Foundation

/// Account-scope reads the download subsystem needs (per-account file
/// isolation + auth-surface host classification). Value-only.
protocol DownloadAccountScopeProviding: Sendable {
    /// The current library's identifier. Backs per-account download-file
    /// scoping (`BookFileManager.fileUrl(for:)`) and the account stamped on a
    /// durable started-task record (`MyBooksDownloadCenter.persistStartedTaskRecord`),
    /// which decides whose credentials answer a resumed background download's auth
    /// challenge. Semantically the defaults-backed `currentAccountId`, not a
    /// resolved-`Account` uuid — a book file must resolve under the selected
    /// library even before its `Account` object has materialized.
    var currentAccountID: String? { get }

    /// Hosts that constitute the current account's auth surface (auth-doc,
    /// catalog, loans, home page), lowercased at the producer. Empty set is the
    /// cold-launch signal (auth doc not yet loaded) — consumers must fall back
    /// to legacy behavior rather than false-block.
    var currentAccountAuthSurfaceHosts: Set<String> { get }
}

/// Resolves the credential-bearing account the download subsystem authenticates
/// against — current library or a captured library UUID (capture-at-start
/// discipline for operations that outlive a library switch).
protocol DownloadCredentialsProviding: Sendable {
    func currentUserAccount() -> any DownloadUserAccount
    func userAccount(forAccount accountID: String) -> any DownloadUserAccount
}

/// The credential/auth capability surface the download subsystem reads and
/// writes on a per-library account. `TPPUserAccount` conforms app-side. Unlike
/// the registry's value-only boundary, the 401-recovery writeback must cross.
protocol DownloadUserAccount: AnyObject, Sendable {
    // Value queries (replace the `authDefinition` object — it never crosses).
    var needsAuth: Bool { get }
    var isSaml: Bool { get }
    var isOidc: Bool { get }
    var reauthStrategy: DownloadReauthStrategy { get }

    /// Mirror of `TPPAccountAuthState`. Named `downloadAuthState` rather than
    /// `authState` because `TPPUserAccount` already declares
    /// `var authState: TPPAccountAuthState` — a same-named property of a
    /// different type would be an invalid redeclaration.
    var downloadAuthState: DownloadAuthState { get }

    // Credential presence + 401-recovery writeback (capability boundary).
    func hasCredentials() -> Bool
    func markCredentialsStale()

    var authToken: String? { get }
    func setAuthToken(_ token: String, barcode: String?, pin: String?, expirationDate: Date?)

    var cookies: [HTTPCookie]? { get }
    func setCookies(_ cookies: [HTTPCookie])

    // Identity fields the download/DRM path stamps into requests.
    var barcode: String? { get }
    var PIN: String? { get }
    var username: String? { get }
    var userID: String? { get }
    var deviceID: String? { get }
}

/// Package-local mirror of `AccountDetails.Authentication.ReauthStrategy`. The
/// app-side adapter maps the real enum here via an EXHAUSTIVE switch, so a new
/// upstream case is a compile error rather than silent `.none` drift.
enum DownloadReauthStrategy: Equatable, Sendable {
    /// Browser-based sign-in flow (SAML IdP, OIDC provider).
    case browser
    /// Programmatic token refresh via tokenURL (OAuth, basic-token).
    case tokenRefresh
    /// Username/password credential prompt.
    case credentialPrompt
    /// No re-auth possible (anonymous, COPPA, unknown).
    case none
}

/// Package-local mirror of `TPPAccountAuthState`. The app-side adapter maps the
/// real `@objc` enum here via an EXHAUSTIVE switch (do NOT move the `@objc`
/// enum into the package). A new upstream case is a compile error here.
enum DownloadAuthState: Equatable, Sendable {
    /// No credentials stored; Adobe DRM deactivated.
    case loggedOut
    /// Fully authenticated; Adobe DRM activated.
    case loggedIn
    /// Session/token expired but Adobe DRM still valid (e.g. SAML cookie expiry).
    case credentialsStale
}
