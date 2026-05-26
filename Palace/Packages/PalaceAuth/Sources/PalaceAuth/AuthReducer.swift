import Foundation
import PalaceCatalog

/// Authentication-method family. `AuthReducer` consumes this instead of
/// `AccountDetails.Authentication` so the reducer stays decoupled from the
/// account model — the live business logic translates from the rich type
/// at the call site.
public enum AuthMethodType: Equatable {
    case basic
    case oauthIntermediary
    case saml
    case oidc
    case token

    /// Methods that route through a 3rd-party browser flow. Refreshing one
    /// of these without using cached credentials must arm
    /// `ignoreSignedInState` so the UI re-auths instead of silently
    /// proceeding with a stale session.
    public var requiresBrowserRefresh: Bool {
        switch self {
        case .saml, .oauthIntermediary, .oidc: return true
        case .basic, .token: return false
        }
    }
}

/// Pure auth state machine state for `AuthReducer`. Captures the slice of
/// `TPPSignInBusinessLogic`'s state that's actually transitioned through
/// the sign-in / refresh / sign-out lifecycle. Excluded by design:
/// - `selectedAuthentication` / `selectedIDP` — owned by the businessLogic
///   and not really transitions, just selections.
/// - `patron: [String: Any]?` — opaque side-channel, not Equatable.
/// - `cookies: [HTTPCookie]?` — SAML side-channel, owned by SAMLHelper.
/// - `userAccount` — persistence layer, side effects in the environment.
public struct AuthState: Equatable {
    public var isValidatingCredentials: Bool = false
    public var isAuthenticationDocumentLoading: Bool = false
    /// While `true`, `isSignedIn()` reports false even if credentials exist.
    /// Mirrors the legacy bypass used during browser-refresh flows where the
    /// IdP session expired but the keychain still has a stale token/cookie.
    public var ignoreSignedInState: Bool = false
    public var isLoggingInAfterSignUp: Bool = false

    /// Captured during `logIn` so `finalizeSignIn` doesn't have to re-read
    /// from the UI delegate, which may have been cleared by an intervening
    /// `accountDidChange` notification.
    public var capturedBarcode: String? = nil
    public var capturedPin: String? = nil

    /// OAuth/OIDC bearer token snapshot. Cleared on sign-out and on a
    /// successful `userAccountUpdated` (the canonical store is
    /// `TPPUserAccount`, not the in-flight reducer state).
    public var authToken: String? = nil
    public var authTokenExpiration: Date? = nil

    /// User-facing error from the most recent failed validation. Surfaced
    /// to the UI delegate's `didEncounterValidationError` callback.
    public var lastErrorTitle: String? = nil
    public var lastErrorMessage: String? = nil

    public init(
        isValidatingCredentials: Bool = false,
        isAuthenticationDocumentLoading: Bool = false,
        ignoreSignedInState: Bool = false,
        isLoggingInAfterSignUp: Bool = false,
        capturedBarcode: String? = nil,
        capturedPin: String? = nil,
        authToken: String? = nil,
        authTokenExpiration: Date? = nil,
        lastErrorTitle: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.isValidatingCredentials = isValidatingCredentials
        self.isAuthenticationDocumentLoading = isAuthenticationDocumentLoading
        self.ignoreSignedInState = ignoreSignedInState
        self.isLoggingInAfterSignUp = isLoggingInAfterSignUp
        self.capturedBarcode = capturedBarcode
        self.capturedPin = capturedPin
        self.authToken = authToken
        self.authTokenExpiration = authTokenExpiration
        self.lastErrorTitle = lastErrorTitle
        self.lastErrorMessage = lastErrorMessage
    }
}

public enum AuthAction: Equatable {
    case authDocumentLoadStarted
    case authDocumentLoadCompleted

    /// User initiated sign-in — capture the typed credentials so a later
    /// `accountDidChange` doesn't wipe them before `finalizeSignIn`.
    case credentialCaptureStarted(barcode: String?, pin: String?)

    case credentialsValidationStarted
    case credentialsValidationSucceeded
    case credentialsValidationFailed(title: String?, message: String?)

    case bearerTokenReceived(token: String, expiration: Date?)

    /// Browser-refresh entry point. The reducer arms
    /// `ignoreSignedInState` only when the auth method requires a
    /// browser flow AND the caller isn't reusing cached credentials —
    /// matches the legacy `refreshAuthIfNeeded` bypass for SAML/OAuth/OIDC.
    case refreshAuthStarted(authType: AuthMethodType, usingExistingCredentials: Bool)

    /// Final commit: keychain + user account write succeeded. Clears the
    /// in-flight state — the canonical credential store is `TPPUserAccount`
    /// from this point forward.
    case userAccountUpdated

    case signOutCompleted
    case errorCleared
    case loggingInAfterSignUpFlagSet(Bool)
}

/// No async effects yet. The environment placeholder keeps the signature
/// compatible with `Store<AuthState, AuthAction, AuthEnvironment>` for a
/// future Phase that wires the network/keychain side effects through the
/// store. Today every transition is synchronous.
public struct AuthEnvironment: Equatable {
    public init() {}
}

/// Namespace holder for the auth state-machine reducer. See
/// `TPPSignInBusinessLogic` for the side-effect surface (network calls,
/// keychain writes, DRM authorization, UI delegate callbacks) — those
/// stay in the business logic. The reducer captures only the
/// state-transition rules so they can be exercised with literal state in
/// `AuthReducerTests` without spinning up a network executor.
public enum AuthReducer {

    public static func reduce(
        _ state: inout AuthState,
        _ action: AuthAction
    ) -> Effect<AuthAction, AuthEnvironment> {
        switch action {

        case .authDocumentLoadStarted:
            state.isAuthenticationDocumentLoading = true
            return .none

        case .authDocumentLoadCompleted:
            state.isAuthenticationDocumentLoading = false
            return .none

        case .credentialCaptureStarted(let barcode, let pin):
            state.capturedBarcode = barcode
            state.capturedPin = pin
            // Starting a fresh sign-in clears any stale error from a
            // previous failed attempt — the UI is about to re-render.
            state.lastErrorTitle = nil
            state.lastErrorMessage = nil
            return .none

        case .credentialsValidationStarted:
            state.isValidatingCredentials = true
            state.lastErrorTitle = nil
            state.lastErrorMessage = nil
            return .none

        case .credentialsValidationSucceeded:
            state.isValidatingCredentials = false
            return .none

        case .credentialsValidationFailed(let title, let message):
            state.isValidatingCredentials = false
            state.lastErrorTitle = title
            state.lastErrorMessage = message
            return .none

        case .bearerTokenReceived(let token, let expiration):
            state.authToken = token
            state.authTokenExpiration = expiration
            return .none

        case .refreshAuthStarted(let authType, let usingExistingCredentials):
            // Browser flows on a non-cached refresh need to surface the
            // re-auth UI; basic/token can keep the current signed-in
            // appearance because they refresh inline without a redirect.
            if authType.requiresBrowserRefresh, !usingExistingCredentials {
                state.ignoreSignedInState = true
            }
            return .none

        case .userAccountUpdated:
            // Canonical store is TPPUserAccount from now on — drop the
            // in-flight mirrors so the next sign-in starts from a clean
            // slate and we don't keep a stale token in memory.
            state.isValidatingCredentials = false
            state.ignoreSignedInState = false
            state.capturedBarcode = nil
            state.capturedPin = nil
            state.authToken = nil
            state.authTokenExpiration = nil
            state.lastErrorTitle = nil
            state.lastErrorMessage = nil
            return .none

        case .signOutCompleted:
            // Same clear as userAccountUpdated, plus the after-signup flag.
            state = AuthState()
            return .none

        case .errorCleared:
            state.lastErrorTitle = nil
            state.lastErrorMessage = nil
            return .none

        case .loggingInAfterSignUpFlagSet(let value):
            state.isLoggingInAfterSignUp = value
            return .none
        }
    }

    /// Static classifier — pure function mirroring the precedence rule
    /// (problem document > network connectivity > generic invalid
    /// credentials) used by `TPPSignInBusinessLogic.userFacingSignInError`.
    /// The strings are intentionally localized via `NSLocalizedString` so
    /// the main bundle's `Localizable.strings` continues to win — the
    /// keys are the English fallbacks used in `Strings.Error.*`.
    public static func classifyValidationError(
        _ error: NSError,
        problemDocument: TPPProblemDocument?
    ) -> (title: String?, message: String?) {
        if let problemDocument {
            return (problemDocument.title, problemDocument.detail)
        }
        // String literals are kept in sync with `Strings.Error.*` in the main
        // target (Palace/Utilities/Localization/Strings.swift). PalaceAuth can't
        // import `Strings`, so the canonical copy is duplicated here; the test
        // suite asserts identity between the two via `Strings.Error.*` lookups.
        if isNetworkConnectivityError(error) {
            return (
                NSLocalizedString("No Internet Connection", comment: ""),
                NSLocalizedString(
                    "Check your connection and try again.",
                    comment: "Message shown when sign-in fails because the device lost connectivity"
                )
            )
        }
        return (
            NSLocalizedString("Invalid Credentials", comment: ""),
            NSLocalizedString(
                "Please check your username and password and try again.",
                comment: ""
            )
        )
    }

    /// True when the error is from URLSession indicating the request never
    /// reached the server (lost connection, DNS failure, TLS handshake, etc).
    /// Mirrors `TPPSignInBusinessLogic.isNetworkConnectivityError` so the
    /// classifier doesn't have to cross the businessLogic boundary.
    public static func isNetworkConnectivityError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
