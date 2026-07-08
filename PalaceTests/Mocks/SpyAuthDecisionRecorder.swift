//
//  SpyAuthDecisionRecorder.swift
//  PalaceTests
//
//  Test spy for `PalaceAuth.AuthDecisionRecording`. Records every emitted
//  payload into an array so tests can assert on count + field values
//  without touching FirebaseCrashlytics.
//
//  Used by `AuthDecisionEventEmissionTests` and `AuthCoordinatorTelemetryTests`
//  in the Palace target. A parallel local spy lives inside the PalaceAuth
//  SPM test target for the SPM-bundle tests; this one is the version that
//  the Xcode test bundle picks up.
//

import Foundation
import PalaceAuth

final class SpyAuthDecisionRecorder: AuthDecisionRecording, @unchecked Sendable {

    private let queue = DispatchQueue(label: "SpyAuthDecisionRecorder")
    private var _recorded: [AuthDecisionPayload] = []

    var recorded: [AuthDecisionPayload] {
        queue.sync { _recorded }
    }

    /// Filter recorded payloads by step — convenience for assertions like
    /// `XCTAssertEqual(spy.events(step: .coordinatorRefreshStarted).count, 1)`.
    func events(step: AuthDecisionStep) -> [AuthDecisionPayload] {
        queue.sync { _recorded.filter { $0.step == step } }
    }

    func clear() {
        queue.sync { _recorded.removeAll() }
    }

    func record(_ payload: AuthDecisionPayload) {
        queue.sync { _recorded.append(payload) }
    }
}
