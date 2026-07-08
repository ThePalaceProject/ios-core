//
//  AuthCoordinator.swift
//  PalaceAuth
//
//  The single public re-auth entrypoint. Every network consumer that
//  observes `AuthOutcome.reauthRequired(...)` calls
//  `refreshCredentialsIfNeeded(reason:)` and awaits the result. The
//  coordinator internally dispatches to the appropriate mechanism (silent
//  token refresh, SAML web sheet, OIDC ASWebAuthenticationSession, basic
//  prompt) based on the active library's authentication type — callers
//  do NOT know which mechanism fires.
//
//  Single-flighted: concurrent calls during an in-flight refresh receive
//  the same outcome the in-flight refresh produces. Eliminates the
//  thundering-herd of N callers all triggering N modals.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// Reasons a `refreshCredentialsIfNeeded` call can fail without yielding
/// a successful re-auth.
public enum AuthRefreshCancellation: Error, Equatable, Sendable {
    /// User dismissed the sign-in modal without completing it.
    case userCancelled

    /// No library is currently selected — the coordinator can't decide
    /// what mechanism to dispatch.
    case noActiveAccount

    /// A previous refresh already failed within the cooldown window;
    /// retrying immediately would just produce the same failure (and on
    /// a token endpoint, risk a refresh loop). Caller should surface the
    /// failure to the user instead.
    case refreshAlreadyFailed

    /// The library's auth mechanism isn't supported by the coordinator
    /// (e.g., a future mechanism added without updating the dispatch
    /// table). Caller should fall back to its legacy path.
    case unsupportedAuthenticationType
}

/// Coordinator actor that owns auth-refresh dispatch. Construct once at
/// composition root (e.g. `AppContainer`); inject everywhere a 401
/// recovery path used to live.
public actor AuthCoordinator {

    // MARK: - Collaborators (injected)

    private let reauthenticator: Reauthenticating
    private let modalPresenter: SignInModalPresenting
    private let userAccount: TPPUserAccountWriting & TPPUserAccountReading
    private let accountProvider: TPPCurrentLibraryAccountProviding
    private let recorder: AuthDecisionRecording
    private let libraryUUIDProvider: @Sendable () -> String?

    // MARK: - Single-flight state

    /// The currently-in-flight refresh task, if any. Concurrent callers
    /// await this task instead of starting a new one.
    private var inFlightRefresh: Task<Result<Void, AuthRefreshCancellation>, Never>?

    /// When the most-recent refresh failed, the timestamp is recorded so
    /// the coordinator can short-circuit subsequent calls within the
    /// cooldown window. This prevents the bearer-token-refresh loop where
    /// callers retry 401s every few seconds and each call kicks off a
    /// fresh refresh attempt.
    private var lastFailureTimestamp: Date?

    /// Cooldown window after a failed refresh. 30 seconds is short
    /// enough that a deliberate retry succeeds (user re-tapped) but long
    /// enough to break the loop. Adjusted per ops experience.
    private let failureCooldown: TimeInterval = 30

    // MARK: - Init

    public init(
        reauthenticator: Reauthenticating,
        modalPresenter: SignInModalPresenting,
        userAccount: TPPUserAccountWriting & TPPUserAccountReading,
        accountProvider: TPPCurrentLibraryAccountProviding,
        recorder: AuthDecisionRecording = NullAuthDecisionRecorder(),
        libraryUUIDProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.reauthenticator = reauthenticator
        self.modalPresenter = modalPresenter
        self.userAccount = userAccount
        self.accountProvider = accountProvider
        self.recorder = recorder
        self.libraryUUIDProvider = libraryUUIDProvider
    }

    // MARK: - Public surface

    /// Refresh credentials for the current library account. The reason
    /// is a HINT from the classifier; the coordinator may dispatch a
    /// different mechanism if the active IdP doesn't support the implied
    /// silent path (e.g., `.expiredToken` for SAML still routes to a
    /// modal because SAML has no client-side refresh).
    ///
    /// Idempotent and single-flighted: concurrent callers from different
    /// 401 sites get the same outcome from the in-flight refresh.
    public func refreshCredentialsIfNeeded(
        reason: ReauthReason,
        correlationID: UUID = UUID(),
        callSite: String = #fileID
    ) async -> Result<Void, AuthRefreshCancellation> {

        // Step 1 — short-circuit if a prior failure is still cooling down.
        if let lastFailure = lastFailureTimestamp,
           Date().timeIntervalSince(lastFailure) < failureCooldown {
            Log.info(#file, "AuthCoordinator: skipping refresh — last failure within cooldown")
            emit(
                step: .coordinatorRefreshCompleted,
                mechanism: accountProvider.currentAccountMechanism,
                decision: "refreshAlreadyFailed",
                callSite: callSite,
                correlationID: correlationID
            )
            return .failure(.refreshAlreadyFailed)
        }

        // Step 2 — single-flight: join an in-flight refresh if one exists.
        if let task = inFlightRefresh {
            return await task.value
        }

        // Step 3 — resolve mechanism. If no active account, fail loudly so
        // the caller doesn't silently wait for a refresh that can't run.
        guard let mechanism = accountProvider.currentAccountMechanism else {
            emit(
                step: .coordinatorRefreshCompleted,
                mechanism: nil,
                decision: "noActiveAccount",
                callSite: callSite,
                correlationID: correlationID
            )
            return .failure(.noActiveAccount)
        }

        // Emit refresh-started ONCE per real refresh (after single-flight
        // gating and after we know we have an account). Skipping the
        // emission inside the cooldown / no-account branches above is
        // intentional — those have their own completion events that
        // include the short-circuit decision, no "started" event needs to
        // pair with them.
        emit(
            step: .coordinatorRefreshStarted,
            mechanism: mechanism,
            decision: "started.\(routeName(reason: reason, mechanism: mechanism))",
            callSite: callSite,
            correlationID: correlationID
        )

        // Step 4 — kick off the refresh task and store it for join.
        let recorder = self.recorder
        let libraryUUIDProvider = self.libraryUUIDProvider
        let task = Task<Result<Void, AuthRefreshCancellation>, Never> { [reauthenticator, modalPresenter, userAccount] in
            await Self.performRefresh(
                reason: reason,
                mechanism: mechanism,
                reauthenticator: reauthenticator,
                modalPresenter: modalPresenter,
                userAccount: userAccount,
                recorder: recorder,
                libraryUUIDProvider: libraryUUIDProvider,
                correlationID: correlationID,
                callSite: callSite
            )
        }
        inFlightRefresh = task

        let outcome = await task.value
        inFlightRefresh = nil

        if case .failure = outcome {
            lastFailureTimestamp = Date()
        } else {
            lastFailureTimestamp = nil
        }

        emit(
            step: .coordinatorRefreshCompleted,
            mechanism: mechanism,
            decision: decisionString(for: outcome),
            callSite: callSite,
            correlationID: correlationID
        )

        return outcome
    }

    // MARK: - Telemetry helpers

    /// SAML helpers emit this when they detect a cookie-validation
    /// failure that hasn't yet surfaced through the classifier. Main
    /// target's SAML helper calls this directly via the injected
    /// coordinator reference.
    public func recordSAMLCookieValidationFailure(
        callSite: String = #fileID,
        correlationID: UUID = UUID()
    ) {
        emit(
            step: .samlCookieValidationFailed,
            mechanism: accountProvider.currentAccountMechanism,
            decision: "reauthRequired.samlSessionExpired",
            callSite: callSite,
            correlationID: correlationID
        )
    }

    /// Token-refresh outcome (proactive or coordinator-driven). Module C
    /// invokes this from `TokenRefreshInterceptor` after every refresh
    /// completes, so the dashboard sees the silent-refresh failure rate
    /// independently of coordinator dispatch.
    public func recordTokenRefreshCompleted(
        succeeded: Bool,
        statusCode: Int?,
        callSite: String = #fileID,
        correlationID: UUID = UUID()
    ) {
        emit(
            step: .tokenRefreshCompleted,
            mechanism: accountProvider.currentAccountMechanism,
            decision: succeeded ? "success" : "failure",
            statusCode: statusCode,
            callSite: callSite,
            correlationID: correlationID
        )
    }

    private func emit(
        step: AuthDecisionStep,
        mechanism: AuthMechanism?,
        decision: String,
        statusCode: Int? = nil,
        callSite: String,
        correlationID: UUID
    ) {
        recorder.record(
            AuthDecisionPayload(
                step: step,
                idpType: AuthDecisionPayload.idpString(for: mechanism),
                libraryUUID: libraryUUIDProvider(),
                statusCode: statusCode,
                problemDocType: nil,
                decision: decision,
                callSite: callSite,
                correlationID: correlationID
            )
        )
    }

    private func decisionString(for result: Result<Void, AuthRefreshCancellation>) -> String {
        switch result {
        case .success:
            return "success"
        case .failure(let cancellation):
            switch cancellation {
            case .userCancelled:                return "userCancelled"
            case .noActiveAccount:              return "noActiveAccount"
            case .refreshAlreadyFailed:         return "refreshAlreadyFailed"
            case .unsupportedAuthenticationType: return "unsupportedAuthenticationType"
            }
        }
    }

    private func routeName(reason: ReauthReason, mechanism: AuthMechanism) -> String {
        switch Self.route(reason: reason, mechanism: mechanism) {
        case .silentRefresh: return "silentRefresh"
        case .modal:         return "modal"
        case .unsupported:   return "unsupported"
        }
    }

    /// Reset the cooldown / in-flight state. Used by tests that want to
    /// drive a second refresh inside the same actor. Not part of the
    /// production surface — call sites in Module C should NOT use this.
    internal func resetForTesting() {
        inFlightRefresh = nil
        lastFailureTimestamp = nil
    }

    /// Force a sign-out + clear. Production sign-out paths still go
    /// through their own surfaces (TPPSignInBusinessLogic+SignOut); this
    /// is the coordinator-mediated sign-out used by `ForceReset`.
    public func signOut() async {
        userAccount.markCredentialsStale()
        // The coordinator does NOT call into the modal presenter on sign
        // out — sign-out is a state mutation, not a re-auth. The actual
        // keychain wipe + IdP logout (where applicable) is owned by
        // `TPPSignInBusinessLogic+SignOut`, which Module C does NOT
        // migrate (explicit off-limits in the contract).
    }

    // MARK: - Internal dispatch

    private static func performRefresh(
        reason: ReauthReason,
        mechanism: AuthMechanism,
        reauthenticator: Reauthenticating,
        modalPresenter: SignInModalPresenting,
        userAccount: TPPUserAccountWriting & TPPUserAccountReading,
        recorder: AuthDecisionRecording,
        libraryUUIDProvider: @Sendable () -> String?,
        correlationID: UUID,
        callSite: String
    ) async -> Result<Void, AuthRefreshCancellation> {

        // Mark stale so other consumers gate on the refresh outcome.
        userAccount.markCredentialsStale()

        // Decide silent-refresh vs modal based on the (reason, mechanism)
        // tuple. The table below is the dispatch matrix from the contract.
        let routing = Self.route(reason: reason, mechanism: mechanism)

        switch routing {
        case .unsupported:
            return .failure(.unsupportedAuthenticationType)

        case .silentRefresh:
            let success = await reauthenticator.authenticateIfNeeded(usingExistingCredentials: true)
            recorder.record(
                AuthDecisionPayload(
                    step: .coordinatorSilentRefresh,
                    idpType: AuthDecisionPayload.idpString(for: mechanism),
                    libraryUUID: libraryUUIDProvider(),
                    statusCode: nil,
                    problemDocType: nil,
                    decision: success ? "success" : "failure",
                    callSite: callSite,
                    correlationID: correlationID
                )
            )
            if success {
                return .success(())
            }
            // Silent refresh failed → fall through to a modal so the
            // user can re-establish credentials interactively.
            return await Self.presentModal(
                modalPresenter: modalPresenter,
                recorder: recorder,
                mechanism: mechanism,
                libraryUUIDProvider: libraryUUIDProvider,
                correlationID: correlationID,
                callSite: callSite
            )

        case .modal:
            return await Self.presentModal(
                modalPresenter: modalPresenter,
                recorder: recorder,
                mechanism: mechanism,
                libraryUUIDProvider: libraryUUIDProvider,
                correlationID: correlationID,
                callSite: callSite
            )
        }
    }

    private static func presentModal(
        modalPresenter: SignInModalPresenting,
        recorder: AuthDecisionRecording,
        mechanism: AuthMechanism,
        libraryUUIDProvider: @Sendable () -> String?,
        correlationID: UUID,
        callSite: String
    ) async -> Result<Void, AuthRefreshCancellation> {
        let success = await modalPresenter.presentSignInModalForCurrentAccount()
        if !success {
            recorder.record(
                AuthDecisionPayload(
                    step: .coordinatorModalCancelled,
                    idpType: AuthDecisionPayload.idpString(for: mechanism),
                    libraryUUID: libraryUUIDProvider(),
                    statusCode: nil,
                    problemDocType: nil,
                    decision: "userCancelled",
                    callSite: callSite,
                    correlationID: correlationID
                )
            )
        }
        return success ? .success(()) : .failure(.userCancelled)
    }

    /// Dispatch table from the contract. Pure function for ease of testing.
    /// - `.silentRefresh` → call reauthenticator silently; fall back to
    ///   modal if it returns false.
    /// - `.modal` → present modal directly.
    /// - `.unsupported` → fail with `.unsupportedAuthenticationType`.
    internal static func route(reason: ReauthReason, mechanism: AuthMechanism) -> RefreshRouting {
        // SAML always presents the modal — the SAML cookie / bearer pair
        // cannot be silently refreshed and the coordinator must surface
        // the web sheet regardless of which `ReauthReason` we got.
        if mechanism == .saml {
            return .modal
        }

        // OIDC has no client-side refresh path at all — every reason
        // routes to the modal so the OIDC ASWebAuthenticationSession can
        // re-establish the IdP session.
        if mechanism == .oidc {
            return .modal
        }

        // OAuth-intermediary (Clever, etc.) — modal is the safe path.
        // Even .expiredToken routes to the modal because the partner
        // callback URL is what produces the new token.
        if mechanism == .oauthIntermediary {
            return .modal
        }

        // Non-browser mechanisms (.basic, .token) can attempt silent
        // refresh for token-expiration scenarios.
        switch reason {
        case .expiredToken:
            return .silentRefresh

        case .invalidCredentials,
             .samlSessionExpired,    // shouldn't fire for non-browser, but route safely
             .oidcRefreshFailed,
             .unknown401:
            // Any reason indicating the user must re-enter creds OR an
            // unknown 401 → modal. .samlSessionExpired/.oidcRefreshFailed
            // shouldn't reach here for .basic/.token (the classifier
            // produces them from problem-doc types that only browser
            // IdPs return), but if a misclassification happens we fail
            // safe to modal rather than silently miss a recovery path.
            return .modal
        }
    }

    internal enum RefreshRouting: Equatable {
        case silentRefresh
        case modal
        case unsupported
    }
}
