//
//  AuthErrorClassifier.swift
//  PalaceAuth
//
//  Pure function: HTTP response tuple → discrete `AuthOutcome`. IdP-agnostic.
//
//  This file EXTENDS the existing boolean classifier in
//  `URLResponse+TPPAuthentication.swift` — it does NOT duplicate the
//  recoverable/unrecoverable/cross-domain logic. The legacy extension
//  returns "should I re-auth?" as a single bool; this classifier converts
//  that bool into the typed `AuthOutcome` and adds discrimination on:
//    - 5xx → .serverError(status:)
//    - nil response → .networkError
//    - 403 + problem-doc → .forbidden(specific reason)
//    - 401 + problem-doc type → .reauthRequired(specific reason)
//
//  The `AuthCoordinator` consumes the outcome and dispatches the actual
//  re-auth mechanism based on the current IdP — the classifier never
//  knows which IdP is active. See `docs/3.2.0-auth-idp-catalog.md` for
//  the full truth table this implementation is fuzzed against.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceCatalog

/// Classifies an HTTP response (or transport failure) into a typed
/// `AuthOutcome`. Pure, stateless, Sendable.
///
/// Construct one per call site (cheap) or share a single instance — the
/// type carries no state besides its injected recorder + account
/// provider (both `Sendable`).
public struct AuthErrorClassifier: Sendable {

    /// Telemetry sink. Defaults to a no-op so callers that don't care
    /// about emission don't have to wire one; the main target replaces
    /// this with a Crashlytics-backed recorder at AppContainer setup.
    private let recorder: AuthDecisionRecording

    /// Closure that returns the active library's auth mechanism for
    /// payload's `idpType` field. PalaceAuth has no `Account` import, so
    /// the main target supplies a tiny closure when wiring AppContainer.
    /// `nil` yields `idpType == "unknown"` on emitted payloads.
    private let mechanismProvider: @Sendable () -> AuthMechanism?

    /// Closure used to read the active library's account UUID for the
    /// telemetry payload's `libraryUUID` field. Same rationale as
    /// `mechanismProvider`. `nil` provider yields `libraryUUID == nil`.
    private let libraryUUIDProvider: @Sendable () -> String?

    /// Closure returning the set of lowercased hosts that constitute the
    /// CURRENT account's auth surface (auth-doc / catalog / loans /
    /// home-page hosts). Used by Rule 4b to short-circuit a 401 from a
    /// host outside that set as `.ok` ("not our account's session").
    ///
    /// Returning `nil` or an empty set disables the host-scoping rule —
    /// the classifier falls back to legacy behavior. Cold-launch trade-off:
    /// while the auth document is still loading, the set is empty and a
    /// 401 from any host is classified per the legacy rules. Better that
    /// transient window than false-blocking a real 401.
    ///
    /// Fixes a regression where a cross-host 401 (e.g. an A1QA audiobook
    /// playtimes POST to `gorgon.staging.palaceproject.io` while the
    /// active account is on `minotaur.dev.palaceproject.io`) was
    /// mis-attributed to the current OIDC/SAML account. The existing
    /// base-domain `isSameDomain` guard does not catch this — both hosts
    /// share `palaceproject.io`. See
    /// `.forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md`.
    private let currentAccountHostsProvider: @Sendable () -> Set<String>?

    // PUBLIC_INTENT: enables current-account host scoping to prevent cross-host 401
    // mis-attribution (PR #1018 regression fix). Default `{ nil }` preserves legacy
    // behavior for existing callers; production wires the closure to the active
    // account's auth-surface hosts.
    public init(
        recorder: AuthDecisionRecording = NullAuthDecisionRecorder(),
        mechanismProvider: @escaping @Sendable () -> AuthMechanism? = { nil },
        libraryUUIDProvider: @escaping @Sendable () -> String? = { nil },
        currentAccountHostsProvider: @escaping @Sendable () -> Set<String>? = { nil }
    ) {
        self.recorder = recorder
        self.mechanismProvider = mechanismProvider
        self.libraryUUIDProvider = libraryUUIDProvider
        self.currentAccountHostsProvider = currentAccountHostsProvider
    }

    /// Map a response tuple to the discrete outcome.
    ///
    /// - Parameters:
    ///   - response: the `HTTPURLResponse`. `nil` means the transport
    ///     itself failed (URLSession completion with an error before any
    ///     HTTP response landed) — classified as `.networkError`.
    ///   - problemDocument: the parsed problem document if the body
    ///     decoded successfully. `nil` either because there's no body or
    ///     because parsing failed (in which case `body` may still have
    ///     bytes that downstream code can inspect).
    ///   - body: raw body bytes. Currently only consulted to log
    ///     malformed-problem-doc situations; future revisions may add
    ///     content-sniffing. Pass `nil` if the body is unavailable.
    ///   - originalRequestURL: the URL before any redirect chain.
    ///     Passed through to the existing same-domain helper so the 401
    ///     CDN guard from URLResponseAuthenticationTests is preserved.
    ///     `nil` falls back to legacy behavior (no cross-domain check).
    ///   - correlationID: optional ID to tie this classifier event to a
    ///     downstream coordinator refresh. Defaults to a fresh UUID;
    ///     callers that want to propagate (e.g. an interceptor → the
    ///     coordinator) pass the same UUID twice. Crashlytics dashboard
    ///     filters on `correlation_id` to reconstruct the flow.
    public func classify(
        response: HTTPURLResponse?,
        problemDocument: TPPProblemDocument?,
        body: Data?,
        originalRequestURL: URL?,
        correlationID: UUID = UUID(),
        callSite: String = #fileID
    ) -> AuthOutcome {
        let outcome = classifyCore(
            response: response,
            problemDocument: problemDocument,
            body: body,
            originalRequestURL: originalRequestURL
        )

        recorder.record(
            AuthDecisionPayload(
                step: .classifierClassified,
                idpType: AuthDecisionPayload.idpString(for: mechanismProvider()),
                libraryUUID: libraryUUIDProvider(),
                statusCode: response?.statusCode,
                problemDocType: problemDocument?.type,
                decision: AuthDecisionPayload.decisionString(for: outcome),
                callSite: callSite,
                correlationID: correlationID
            )
        )

        return outcome
    }

    // Pure classification (no side effects). Split out so the public
    // entrypoint can compute the outcome first, then emit telemetry
    // shaped by the outcome — emission is one event per call regardless
    // of which branch fired.
    private func classifyCore(
        response: HTTPURLResponse?,
        problemDocument: TPPProblemDocument?,
        body: Data?,
        originalRequestURL: URL?
    ) -> AuthOutcome {
        // Rule 1: nil response → network failed before any HTTP arrived.
        guard let response else {
            return .networkError
        }

        let status = response.statusCode

        // Rule 2: 2xx → success.
        if (200...299).contains(status) {
            return .ok
        }

        // Rule 3: 5xx → server error (separate from auth outcomes).
        if (500...599).contains(status) {
            return .serverError(status: status)
        }

        // Rule 4: cross-domain 401 → .ok (third-party CDN, not our creds).
        // Delegates to the existing helper so we don't duplicate the rule.
        // Base-domain match: e.g. cdn.palaceproject.io and
        // gorgon.palaceproject.io share base `palaceproject.io` → same.
        if status == 401, let originalURL = originalRequestURL,
           !response.isSameDomain(as: originalURL) {
            return .ok
        }

        // Rule 4b: foreign-host 401 → .ok (not our account's session).
        //
        // The base-domain check in Rule 4 catches biblioboard vs
        // palaceproject CDN, but it does NOT catch the case where two
        // library backends share the SAME base domain but live on
        // different hosts — e.g. `gorgon.staging.palaceproject.io`
        // (A1QA) vs `minotaur.dev.palaceproject.io` (Icarus). A 401
        // from a host outside the current account's auth surface is
        // never an expiry of the current account's session; classify
        // as `.ok` so the responder + sibling sites short-circuit
        // before marking the current account stale or dispatching the
        // coordinator. PR #1018 regression fix; see wall-failure
        // 2026-06-05-pr1018-icarus-cross-host-logout.md.
        //
        // Empty set is treated like a nil provider (legacy behavior):
        // during cold launch the auth document is still loading, so
        // false-blocking a real 401 would be worse than the transient
        // legacy-behavior window. Case-insensitive comparison is
        // belt-and-braces — Account.authSurfaceHosts also lowercases.
        if status == 401,
           let originalURL = originalRequestURL,
           let host = originalURL.host?.lowercased(),
           let currentHosts = currentAccountHostsProvider(),
           !currentHosts.isEmpty,
           !currentHosts.contains(host) {
            return .ok
        }

        // 401 handling: delegate the recoverable/unrecoverable decision
        // to the existing extension's boolean, then map the *kind*.
        if status == 401 {
            return classify401(response: response, problemDocument: problemDocument, body: body)
        }

        // 403 handling: specific forbidden reasons vs. unknown.
        if status == 403 {
            return classify403(response: response, problemDocument: problemDocument)
        }

        // OPDS authentication-document responses with any non-2xx status
        // are an explicit auth challenge from the server — surface as
        // reauth-required regardless of the numeric code. Preserves
        // URLResponseAuthenticationTests.testHTTPURLResponse_withOPDSAuthMimeType_andNon2xxStatus_returnsTrue.
        if response.mimeType == "application/vnd.opds.authentication.v1.0+json" {
            return .reauthRequired(reason: .unknown401)
        }

        // Catch-all for other 4xx and any 1xx/3xx that somehow reach the
        // classifier. Map to .serverError so callers know it isn't an
        // auth outcome. (3xx normally never reaches here — URLSession
        // follows redirects by default.)
        return .serverError(status: status)
    }

    // MARK: - Status-specific helpers

    private func classify401(
        response: HTTPURLResponse,
        problemDocument: TPPProblemDocument?,
        body: Data?
    ) -> AuthOutcome {
        // OPDS authentication-document responses always re-auth (legacy
        // behavior preserved from `URLResponse+TPPAuthentication`).
        if response.mimeType == "application/vnd.opds.authentication.v1.0+json" {
            return .reauthRequired(reason: .unknown401)
        }

        // No problem doc → bare 401 (legacy server) or malformed body.
        // The malformed case is when MIME is problem+json but problemDocument
        // is nil — same outcome: fall back to the bare-401 hint.
        guard let problemDocument else {
            return .reauthRequired(reason: .unknown401)
        }

        // Recoverable: map the type to a specific reason hint.
        if problemDocument.isRecoverableAuthError {
            return .reauthRequired(reason: recoverableReason(for: problemDocument.type))
        }

        // Unrecoverable: user must re-enter credentials.
        if problemDocument.isUnrecoverableAuthError {
            return .reauthRequired(reason: .invalidCredentials)
        }

        // Legacy credentials-invalid type (older servers, pre-categorization).
        if problemDocument.type == TPPProblemDocument.TypeInvalidCredentials {
            return .reauthRequired(reason: .invalidCredentials)
        }

        // TypeNoActiveLoan — IdP-agnostic recoverable signal that the
        // server side has cleared the loan and we should re-auth.
        // The coordinator dispatches the appropriate mechanism per IdP.
        if problemDocument.type == TPPProblemDocument.TypeNoActiveLoan {
            return .reauthRequired(reason: .expiredToken)
        }

        // Problem doc was present but wasn't an auth-categorized type.
        // Fall back to the bare-401 hint; coordinator will modal.
        _ = body // reserved for future content-sniffing
        return .reauthRequired(reason: .unknown401)
    }

    private func classify403(
        response: HTTPURLResponse,
        problemDocument: TPPProblemDocument?
    ) -> AuthOutcome {
        guard let problemDocument, let type = problemDocument.type else {
            return .forbidden(reason: .unknown403)
        }

        // Specific 403 reasons (license, geo, account suspension).
        if let reason = forbiddenReason(for: type) {
            return .forbidden(reason: reason)
        }

        // Edge case: a recoverable auth error returned at 403 status.
        // Surface as reauth-required (.invalidCredentials) so the
        // coordinator at least surfaces a modal rather than swallowing it.
        if problemDocument.isRecoverableAuthError {
            return .reauthRequired(reason: .invalidCredentials)
        }

        _ = response // reserved for future MIME inspection
        return .forbidden(reason: .unknown403)
    }

    // MARK: - Type → reason mapping

    private func recoverableReason(for type: String?) -> ReauthReason {
        guard let type else { return .unknown401 }

        // SAML-specific recoverable types take precedence — the
        // coordinator needs to know to present the SAML web sheet, not
        // attempt a silent token refresh.
        if type.contains("/auth/recoverable/saml/") {
            return .samlSessionExpired
        }

        if type.contains("/auth/recoverable/token/") {
            return .expiredToken
        }

        // Future-proof: a recoverable type the classifier hasn't grown
        // a case for. The coordinator falls back to a modal for the
        // active IdP — safer than guessing.
        return .unknown401
    }

    private func forbiddenReason(for type: String) -> ForbiddenReason? {
        if type.contains("/license-expired") {
            return .licenseExpired
        }
        if type.contains("/geo-restriction") {
            return .geoRestriction
        }
        if type == TPPProblemDocument.TypeCredentialsSuspended
            || type.contains("/credentials-suspended")
            || type.contains("/account-suspended") {
            return .accountSuspended
        }
        if type.contains("/content-protected") {
            return .contentProtected
        }
        return nil
    }
}
