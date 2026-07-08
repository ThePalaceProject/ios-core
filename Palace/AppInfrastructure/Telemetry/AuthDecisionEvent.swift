//
//  AuthDecisionEvent.swift
//  Palace
//
//  Main-target Error wrapper around `PalaceAuth.AuthDecisionPayload`.
//  Lives outside the PalaceAuth package so we don't drag FirebaseCrashlytics
//  into the SPM module (PalaceAuth must stay dependency-clean).
//
//  Crashlytics consumes any `Error` that conforms to `CustomNSError`. The
//  `errorUserInfo` dictionary becomes the keys/values that appear in the
//  dashboard under each non-fatal — that's how `idp_type`,
//  `library_uuid`, `decision`, `correlation_id`, etc become filterable
//  facets. The `errorCode` distinguishes auth-decision events from other
//  non-fatals (e.g., PR #933's playback-failure events).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAuth

/// Crashlytics-shaped wrapper around an `AuthDecisionPayload`. The
/// payload carries the data; this wrapper is the Error conformance that
/// `Crashlytics.crashlytics().record(error:)` requires.
///
/// `errorDomain` is stable so dashboard rules can subscribe to all auth
/// decisions; `errorCode` partitions by `AuthDecisionStep` so the rule
/// engine can route classifier events vs coordinator events.
public struct AuthDecisionEvent: Error, CustomNSError {

    /// The underlying payload from PalaceAuth.
    public let payload: AuthDecisionPayload

    public init(payload: AuthDecisionPayload) {
        self.payload = payload
    }

    // MARK: - CustomNSError conformance

    /// Stable domain for all auth-decision non-fatals. Crashlytics
    /// dashboard rules subscribe to this; PR #933 playback-failure events
    /// use a different domain so the two non-fatal classes don't mix.
    public static let errorDomain = "org.thepalaceproject.palace.AuthDecision"

    /// Per-step error code. Keeps the partition deterministic so dashboard
    /// alert rules can subscribe to "classifier 401 spike" independently
    /// from "coordinator modal-cancel spike".
    public var errorCode: Int {
        switch payload.step {
        case .classifierClassified:        return 1001
        case .coordinatorRefreshStarted:   return 1002
        case .coordinatorRefreshCompleted: return 1003
        case .coordinatorModalCancelled:   return 1004
        case .coordinatorSilentRefresh:    return 1005
        case .samlCookieValidationFailed:  return 1006
        case .tokenRefreshCompleted:       return 1007
        }
    }

    /// Flat dictionary of fields the dashboard exposes for filtering.
    /// Sourced from `AuthDecisionPayload.dashboardFields` so the PalaceAuth
    /// payload retains the canonical shape and the main target just maps
    /// the keys verbatim into `userInfo`.
    public var errorUserInfo: [String: Any] {
        // Map String:String into String:Any. NSLocalizedDescriptionKey is
        // included so Crashlytics' default description shows the decision
        // rather than the raw error code.
        var userInfo: [String: Any] = [:]
        for (key, value) in payload.dashboardFields {
            userInfo[key] = value
        }
        userInfo[NSLocalizedDescriptionKey] = "\(payload.step.rawValue): \(payload.decision)"
        return userInfo
    }
}
