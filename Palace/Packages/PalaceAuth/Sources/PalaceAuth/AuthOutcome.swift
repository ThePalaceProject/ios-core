//
//  AuthOutcome.swift
//  PalaceAuth
//
//  Discrete, IdP-agnostic outcome of an auth-related HTTP response.
//
//  Produced by `AuthErrorClassifier.classify(...)` from the (response,
//  problem-document, body, originalRequestURL) tuple alone — the classifier
//  knows nothing about the active IdP. `AuthCoordinator` is the consumer
//  that maps `AuthOutcome` to a re-auth mechanism for the current
//  authentication type.
//
//  Catalogued against `docs/3.2.0-auth-idp-catalog.md` (38 grounded rows +
//  11 UNKNOWN-pending-recording). Adding a new case to any of these enums
//  must update both the catalog and the property-test invariants in
//  `AuthErrorClassifierPropertyTests`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Top-level outcome returned by `AuthErrorClassifier`.
///
/// Every HTTP response (or transport failure) partitions into exactly one
/// case — property-test invariant #1 in
/// `AuthErrorClassifierPropertyTests`.
public enum AuthOutcome: Equatable, Sendable {
    /// Response is acceptable and no auth action is required. Includes
    /// 2xx success codes and the cross-domain 401 carve-out (a 401 from a
    /// different base domain than the original request is treated as a
    /// third-party CDN issue, not a credentials issue).
    case ok

    /// Credentials need to be refreshed. The associated `ReauthReason`
    /// is a hint to the coordinator — the coordinator decides whether the
    /// hint maps to a silent token refresh, a SAML web sheet, or an OIDC
    /// browser dance based on the active authentication type.
    case reauthRequired(reason: ReauthReason)

    /// 403-class outcome: the request was rejected for reasons re-auth
    /// won't fix. The coordinator surfaces a user-facing message; it does
    /// NOT trigger a sign-in flow.
    case forbidden(reason: ForbiddenReason)

    /// 5xx response. Caller should retry per its own retry policy; this
    /// is not an auth issue.
    case serverError(status: Int)

    /// The transport itself failed (URLSession completion produced an
    /// error before any HTTP response). No HTTP status is available.
    case networkError
}

/// Hint for `AuthCoordinator` describing what KIND of credential needs to
/// be refreshed. The coordinator combines this with the active IdP to
/// select a mechanism — these cases do NOT name a mechanism by themselves.
public enum ReauthReason: Equatable, Sendable {
    /// A bearer token has expired and (for IdPs that support silent
    /// refresh) can likely be renewed without user interaction. For IdPs
    /// without client-side refresh (OIDC, SAML), the coordinator falls
    /// back to a modal.
    case expiredToken

    /// The credentials are no longer valid and the user must re-enter
    /// them. Server signalled this via an "unrecoverable" problem doc or
    /// the legacy `credentials-invalid` type.
    case invalidCredentials

    /// SAML-specific recoverable signal — bearer-token-invalid,
    /// saml-session-expired, or any 401 whose problem-doc type indicates
    /// the IdP session needs to be re-established. Coordinator presents
    /// the SAML web sheet.
    case samlSessionExpired

    /// OIDC-specific recoverable signal — the OIDC IdP session expired
    /// and OIDC has no client-side refresh path. Coordinator presents the
    /// OIDC ASWebAuthenticationSession.
    case oidcRefreshFailed

    /// 401 received but the problem document did not identify the cause
    /// (bare 401 from legacy server, malformed problem doc, OPDS auth
    /// document response, etc). Coordinator falls back to a modal for the
    /// active IdP.
    case unknown401
}

/// Hint for `AuthCoordinator` describing why a 403 was returned. The
/// coordinator does NOT trigger re-auth for any `ForbiddenReason` —
/// these are user-facing error states.
public enum ForbiddenReason: Equatable, Sendable {
    /// DRM license has expired server-side. The book/audiobook is no
    /// longer playable; user should be told the license expired.
    case licenseExpired

    /// Patron's geographic location is outside the library's service
    /// area (typically OAuth-intermediary district mismatches).
    case geoRestriction

    /// Patron's account has been administratively suspended.
    case accountSuspended

    /// Content-level protection prevented the action (e.g., already
    /// returned, not actually loaned).
    case contentProtected

    /// 403 received but no recognized problem-document type. Coordinator
    /// surfaces a generic "forbidden" message.
    case unknown403
}
