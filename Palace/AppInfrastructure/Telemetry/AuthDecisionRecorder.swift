//
//  AuthDecisionRecorder.swift
//  Palace
//
//  Main-target conformance to PalaceAuth's `AuthDecisionRecording`
//  protocol. Wraps `Crashlytics.crashlytics().record(error:)` so PalaceAuth
//  stays Firebase-free; AppContainer wires this single instance into the
//  classifier + coordinator at construction time.
//
//  The recorder is intentionally `final` (this IS a leaf type — no tests
//  need to subclass it; tests use `SpyAuthDecisionRecorder` from
//  PalaceTests/Mocks/) and `Sendable` so the actor-isolated coordinator
//  can hold it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import FirebaseCrashlytics
import PalaceAuth

/// Production `AuthDecisionRecording` conformance. Ships each payload
/// to Firebase Crashlytics as a non-fatal `Error`.
///
/// Mirrors the PR #933 playback-failure pattern: one Error per decision,
/// the dashboard groups by `errorDomain` + `errorCode`, individual fields
/// (idp, library, status, etc.) live in `userInfo`. Frequency budget is
/// enforced upstream in PalaceAuth — the contract caps at ~10 events per
/// auth flow, sampling at the classifier event if needed.
public final class AuthDecisionRecorder: AuthDecisionRecording {

    public init() {}

    public func record(_ payload: AuthDecisionPayload) {
        let event = AuthDecisionEvent(payload: payload)
        Crashlytics.crashlytics().record(error: event)
    }
}
