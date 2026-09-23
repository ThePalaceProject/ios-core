//
//  FirebaseTriageTelemetrySink.swift
//  Palace
//
//  Production TelemetrySink for the PalaceTriageBot package. Forwards triage-bot
//  events to Firebase Analytics in release builds, replacing OSLogTelemetrySink
//  (see TriageBotFactory, PP-4814).
//
//  Host-side, NOT in the package: Firebase is a Palace-target dependency and the
//  package deliberately stays SDK-free + KMP-portable. This file therefore cannot
//  build in a package-only worktree — it is CI-gated.
//
//  Privacy contract: TelemetryEvents already carry only ids / counts / enum
//  categories (never free text). As a defense-in-depth boundary, this sink runs
//  every event through TelemetryContract.enumerableParameters so that even if a
//  future caller attaches a non-enumerable (free-text) key, it is dropped before
//  anything reaches Analytics.
//

import Foundation
import FirebaseAnalytics
import TriageBotCore

struct FirebaseTriageTelemetrySink: TelemetrySink {

    func emit(_ event: TelemetryEvent) {
        let parameters = TelemetryContract.enumerableParameters(of: event)
        Analytics.logEvent(event.name, parameters: parameters.isEmpty ? nil : parameters)
    }
}
