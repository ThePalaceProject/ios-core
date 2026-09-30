//
//  FirebaseTriageTelemetrySink.swift
//  Palace
//
//  Production TelemetrySink for PalaceTriageBot: forwards events to Firebase
//  Analytics in release builds (PP-4814). Lives in the app target because the
//  package stays SDK-free. Every event goes through
//  TelemetryContract.enumerableParameters so a free-text key is dropped before
//  it reaches Analytics.
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
