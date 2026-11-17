//
//  TPPSignInBusinessLogic+LibraryDocument.swift
//  Palace
//
//  Reads of the authentication document for the library this object signs in
//  to, which Settings opens for any library the patron taps — not only the
//  selected one (PP-5390).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

extension TPPSignInBusinessLogic {

    /// The parsed authentication document for the library this object signs in
    /// to, including when that library is not the selected one.
    ///
    /// `loadedAccountDetails` is nil on every state but `.detailsLoaded`, and
    /// only the selected library is driven there: a library the patron switched
    /// away from is pinned at `.detailsEvicted` so `awaitReady()` callers fail
    /// fast and redrive on return, and nothing re-drives it while it stays
    /// deselected. Settings signs in and out for ANY library, so the sites that
    /// need only the document — which auth methods exist, where to post
    /// credentials — read this. `.detailsLoading` is deliberately not included:
    /// a fetch in flight must still refuse the request rather than act on the
    /// document it is replacing.
    var signInTargetDetails: AccountDetails? {
        if let loaded = loadedAccountDetails { return loaded }
        // Bound to the deselection marker specifically: a future eviction
        // reason must be considered on its own merits rather than inheriting
        // this fallback, as `driveCurrentAccountAuthDocIfNeeded` requires of
        // its own arm.
        guard let account = libraryAccount,
              case .detailsEvicted(.libraryDeselected) = account.loadState else { return nil }
        return account.details
    }

    /// Whether the library this object signs in to collects patron credentials,
    /// read from that library's own authentication document.
    ///
    /// Distinct from `TPPUserAccount.needsAuth`, which is derived from the auth
    /// definition stored at sign-in and is therefore false for every library the
    /// patron has not signed into yet. Falls back to the stored definition while
    /// the document is unavailable.
    var libraryCollectsCredentials: Bool {
        if let details = signInTargetDetails { return details.needsAuth }
        return userAccount.needsAuth
    }

    /// Auto-select a WebView-based authentication (SAML, then OIDC) when
    /// the library advertises multiple auth methods and none is explicitly
    /// chosen. Fixes the regression where multi-auth SAML libraries rendered
    /// the basic-auth credential fields instead of the SAML sign-in prompt.
    ///
    /// Also auto-selects the sole SAML IdP when the chosen SAML auth
    /// advertises exactly one — without this, tapping "Sign in" on a
    /// single-IdP SAML library is a silent no-op because
    /// `samlHelper.logIn()` guards on `selectedIDP?.url`.
    ///
    /// Idempotent: only sets `selectedAuthentication` / `selectedIDP` when
    /// they are currently nil.
    @objc func selectPreferredAuthIfNeeded() {
        if selectedAuthentication == nil, let auths = signInTargetDetails?.auths {
            // Name a sole SIGN-IN method explicitly. The getter derives it from
            // the account state machine, which only the selected library is
            // driven through, so on any other library it stays nil and
            // `logIn()` parks on the readiness gate and drops the tap
            // (PP-5390). On the selected library this is the value the getter
            // already returned.
            //
            // An age gate is excluded: it is not a sign-in method, and naming
            // it would put the age-check row on a deselected library's page,
            // where `TPPAgeCheck` cannot present the picker and answers the
            // check `false` — which resets that library's downloads and
            // registry.
            if auths.count == 1, let onlyAuth = auths.first, !onlyAuth.needsAgeCheck {
                selectedAuthentication = onlyAuth
            } else if let saml = auths.first(where: { $0.isSaml }) {
                selectedAuthentication = saml
            } else if let oidc = auths.first(where: { $0.isOidc }) {
                selectedAuthentication = oidc
            }
        }

        // Auto-select the sole SAML IdP so Sign In opens the WebView
        // immediately instead of silently no-op'ing. Multi-IdP libraries
        // still require the user to pick via the IdP list UI.
        if selectedIDP == nil,
           let samlAuth = selectedAuthentication,
           samlAuth.isSaml,
           let idps = samlAuth.samlIdps,
           idps.count == 1 {
            selectedIDP = idps.first
        }
    }
}
