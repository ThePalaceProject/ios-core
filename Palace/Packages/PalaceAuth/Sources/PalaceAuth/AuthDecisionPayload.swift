//
//  AuthDecisionPayload.swift
//  PalaceAuth
//
//  Pure value-type payload describing a single auth decision. Designed to
//  cross the PalaceAuth boundary without dragging in FirebaseCrashlytics —
//  the main-target wrapper (`AuthDecisionEvent`) consumes this struct and
//  ships it to Crashlytics via its `Error` / `CustomNSError` conformance.
//
//  Each decision point in PalaceAuth (`AuthErrorClassifier.classify`,
//  `AuthCoordinator.refreshCredentialsIfNeeded` start/end, modal cancel,
//  silent-refresh outcome) constructs one payload and hands it to the
//  injected `AuthDecisionRecording` recorder. Tests use `SpyAuthDecisionRecorder`
//  (in PalaceTests/Mocks/) to assert payload shape + emission counts.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Discrete step within an auth decision flow. Distinguishes the
/// classifier event (input-driven, IdP-agnostic) from the coordinator
/// steps (output-driven, IdP-specific). Used as a Crashlytics dashboard
/// filter so we can group "all classifier 401s for Cornell" vs "all
/// coordinator silent-refresh failures".
public enum AuthDecisionStep: String, Sendable, Equatable {
    /// `AuthErrorClassifier.classify(...)` returned an outcome.
    case classifierClassified = "classifier.classified"

    /// `AuthCoordinator.refreshCredentialsIfNeeded` began processing.
    /// One payload per call, before the dispatch table runs.
    case coordinatorRefreshStarted = "coordinator.refresh.started"

    /// `AuthCoordinator.refreshCredentialsIfNeeded` returned a final
    /// result. One payload per call, paired with `coordinatorRefreshStarted`
    /// via `correlationID`.
    case coordinatorRefreshCompleted = "coordinator.refresh.completed"

    /// The modal was dismissed by user cancel. Subset of
    /// `coordinatorRefreshCompleted` for ease of filtering — the
    /// coordinator emits BOTH the completed event AND this one when the
    /// modal returns `false`. (Dashboard filter convenience; not a
    /// behavioral signal.)
    case coordinatorModalCancelled = "coordinator.modal.cancelled"

    /// A silent token refresh attempt finished. Emitted from inside the
    /// coordinator's dispatch when the reauthenticator returns; the
    /// `success` flag rides on the payload's `succeeded` field.
    case coordinatorSilentRefresh = "coordinator.silent.refresh"

    /// The classifier or coordinator observed a SAML cookie-validation
    /// failure surfaced by the SAML helper. Specific subset of the
    /// classifier event used for fast SAML-cookie regression triage.
    case samlCookieValidationFailed = "saml.cookie.validation.failed"

    /// Bookkeeping — token refresh completed (success or failure)
    /// regardless of whether it was triggered by classifier outcome or
    /// proactive foreground refresh. Distinct from
    /// `coordinatorSilentRefresh` because this event fires for proactive
    /// refresh too (where the coordinator wasn't the trigger).
    case tokenRefreshCompleted = "token.refresh.completed"
}

/// One Crashlytics non-fatal-shaped record describing a single auth
/// decision. PalaceAuth constructs this and hands it to the injected
/// `AuthDecisionRecording`; the main-target wrapper converts to an
/// `Error` for `Crashlytics.crashlytics().record(error:)`.
///
/// The payload is intentionally **flat** (no nested structs) so the
/// Crashlytics dashboard `userInfo` table renders one row per field.
public struct AuthDecisionPayload: Sendable, Equatable {

    /// Which decision point emitted this event.
    public let step: AuthDecisionStep

    /// Stringified IdP type: "basic" / "oauth" / "oidc" / "saml" /
    /// "token" / "unknown". Lowercase. Matches the catalog vocabulary in
    /// `docs/3.2.0-auth-idp-catalog.md`.
    public let idpType: String

    /// Current library account UUID, or `nil` when no library is
    /// selected (cold launch, between accounts). Crashlytics dashboard
    /// pivots on this for per-library regression triage.
    public let libraryUUID: String?

    /// HTTP status code from the response that triggered this decision.
    /// `nil` for network errors (no HTTP response landed) and for
    /// proactive coordinator events that don't have a response.
    public let statusCode: Int?

    /// Problem-document `type` URI string, or `nil` when no problem doc
    /// was returned. Matches `TPPProblemDocument.type` exactly so the
    /// dashboard can filter by full URI without partial-match hacks.
    public let problemDocType: String?

    /// Classifier or coordinator decision summary as a short stable
    /// string. For the classifier: `"ok"` / `"reauthRequired.expiredToken"`
    /// / `"forbidden.licenseExpired"` / etc. For the coordinator:
    /// `"success"` / `"userCancelled"` / `"refreshAlreadyFailed"` /
    /// `"noActiveAccount"` / `"unsupportedAuthenticationType"`.
    public let decision: String

    /// Source-location hint — `#fileID` of the emission point.
    /// Crashlytics breadcrumbs use this to disambiguate identical
    /// outcomes from different call sites (classifier vs coordinator vs
    /// SAML helper).
    public let callSite: String

    /// Identifier that ties classifier event ↔ coordinator start ↔
    /// coordinator end across a single auth flow. The classifier
    /// generates a fresh UUID per call; the coordinator reuses it if
    /// available (when the caller passed it through) or generates its
    /// own start UUID and reuses it for the matching end event.
    public let correlationID: UUID

    /// Wall-clock timestamp at emission. Used for sequence reconstruction
    /// in the Crashlytics dashboard (multiple events from one flow land
    /// out of order otherwise).
    public let timestamp: Date

    public init(
        step: AuthDecisionStep,
        idpType: String,
        libraryUUID: String?,
        statusCode: Int?,
        problemDocType: String?,
        decision: String,
        callSite: String,
        correlationID: UUID = UUID(),
        timestamp: Date = Date()
    ) {
        self.step = step
        self.idpType = idpType
        self.libraryUUID = libraryUUID
        self.statusCode = statusCode
        self.problemDocType = problemDocType
        self.decision = decision
        self.callSite = callSite
        self.correlationID = correlationID
        self.timestamp = timestamp
    }

    /// Field-by-field dictionary for the main-target wrapper to forward
    /// into `errorUserInfo`. Stable keys; absent fields drop the key
    /// rather than emit a `<nil>` string so dashboard filters work.
    public var dashboardFields: [String: String] {
        var result: [String: String] = [
            "step": step.rawValue,
            "idp_type": idpType,
            "decision": decision,
            "call_site": callSite,
            "correlation_id": correlationID.uuidString,
            "timestamp_iso": Self.makeISO8601Formatter().string(from: timestamp)
        ]
        if let libraryUUID { result["library_uuid"] = libraryUUID }
        if let statusCode { result["status_code"] = String(statusCode) }
        if let problemDocType { result["problem_doc_type"] = problemDocType }
        return result
    }

    // Localized per call (playbook: a shared non-Sendable ISO8601DateFormatter
    // static is a #MutableGlobalVariable under Swift 6; never nonisolated(unsafe)).
    // Called once per telemetry payload — not a hot path, so per-call allocation
    // is fine and keeps the formatter provably race-free.
    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

// MARK: - Convenience constructors

extension AuthDecisionPayload {

    /// Map an `AuthOutcome` to the `decision` string used on the
    /// classifier event. Keeps the mapping in one place so the dashboard
    /// strings stay stable.
    public static func decisionString(for outcome: AuthOutcome) -> String {
        switch outcome {
        case .ok:
            return "ok"
        case .reauthRequired(let reason):
            return "reauthRequired.\(reauthReasonString(reason))"
        case .forbidden(let reason):
            return "forbidden.\(forbiddenReasonString(reason))"
        case .serverError(let status):
            return "serverError.\(status)"
        case .networkError:
            return "networkError"
        }
    }

    /// Stable string form of an `AuthMechanism` for the `idpType` field.
    /// `nil` mechanism (no active library) maps to `"unknown"` rather
    /// than empty so dashboard filters don't drop the row.
    public static func idpString(for mechanism: AuthMechanism?) -> String {
        guard let mechanism else { return "unknown" }
        switch mechanism {
        case .basic:             return "basic"
        case .token:             return "token"
        case .oauthIntermediary: return "oauth"
        case .saml:              return "saml"
        case .oidc:              return "oidc"
        }
    }

    private static func reauthReasonString(_ reason: ReauthReason) -> String {
        switch reason {
        case .expiredToken:        return "expiredToken"
        case .invalidCredentials:  return "invalidCredentials"
        case .samlSessionExpired:  return "samlSessionExpired"
        case .oidcRefreshFailed:   return "oidcRefreshFailed"
        case .unknown401:          return "unknown401"
        }
    }

    private static func forbiddenReasonString(_ reason: ForbiddenReason) -> String {
        switch reason {
        case .licenseExpired:    return "licenseExpired"
        case .geoRestriction:    return "geoRestriction"
        case .accountSuspended:  return "accountSuspended"
        case .contentProtected:  return "contentProtected"
        case .unknown403:        return "unknown403"
        }
    }
}

// MARK: - AuthDecisionRecording

/// Recorder seam. PalaceAuth holds one of these via dependency injection;
/// main target conforms with a Crashlytics-wrapping implementation, tests
/// use a spy that records into an array.
///
/// `Sendable` so the actor-isolated coordinator can hold an instance.
/// No requirement that the implementation be thread-safe beyond the
/// `Sendable` contract — calls cross actors infrequently and the
/// production Crashlytics implementation is already thread-safe.
public protocol AuthDecisionRecording: Sendable {
    /// Record one decision event. Implementations are fire-and-forget;
    /// callers do not await a result. Crashlytics's own backing call is
    /// synchronous from the caller's perspective but ships to Firebase
    /// asynchronously.
    func record(_ payload: AuthDecisionPayload)
}

/// Default no-op recorder. PalaceAuth defaults to this when no recorder
/// is injected, so callers (tests, third-party PalaceAuth consumers,
/// previews) that don't care about telemetry don't have to wire one. The
/// main target replaces this with `AuthDecisionRecorder` at AppContainer
/// construction time.
public struct NullAuthDecisionRecorder: AuthDecisionRecording {
    public init() {}
    public func record(_ payload: AuthDecisionPayload) {
        // intentionally empty — no-op default
    }
}
