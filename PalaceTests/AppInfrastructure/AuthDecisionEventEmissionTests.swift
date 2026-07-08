//
//  AuthDecisionEventEmissionTests.swift
//  PalaceTests
//
//  Main-target tests for `AuthDecisionEvent` — the `CustomNSError`
//  wrapper that ships an `AuthDecisionPayload` to Crashlytics. These
//  pin the contract Crashlytics dashboard rules depend on:
//
//  - `errorDomain` stable per package, partitioned from PR #933 events
//  - `errorCode` partitioned by step so rules can subscribe per-step
//  - `errorUserInfo` flattens `dashboardFields` verbatim + adds
//    `NSLocalizedDescriptionKey` for the default Crashlytics row label
//

import XCTest
import PalaceAuth
@testable import Palace

final class AuthDecisionEventEmissionTests: XCTestCase {

    // MARK: - errorDomain

    func testErrorDomain_isStableValue_distinctFromPlaybackFailureDomain() {
        // Locked literal. Changing it breaks Crashlytics dashboard rules
        // and means PR #933 playback-failure events get accidentally
        // grouped with auth-decision events.
        XCTAssertEqual(AuthDecisionEvent.errorDomain,
                       "org.thepalaceproject.palace.AuthDecision")
    }

    // MARK: - errorCode partitioning per step

    func testErrorCode_partitionsPerStep_eachStepGetsDistinctCode() {
        let steps: [AuthDecisionStep] = [
            .classifierClassified,
            .coordinatorRefreshStarted,
            .coordinatorRefreshCompleted,
            .coordinatorModalCancelled,
            .coordinatorSilentRefresh,
            .samlCookieValidationFailed,
            .tokenRefreshCompleted
        ]
        var codes: Set<Int> = []
        for step in steps {
            let event = AuthDecisionEvent(payload: payload(step: step))
            codes.insert(event.errorCode)
        }
        XCTAssertEqual(codes.count, steps.count,
            "every AuthDecisionStep must map to a unique errorCode so dashboard alert rules can target one step")
    }

    func testErrorCode_classifierClassified_is1001() {
        // Lock literal — a renumbering would silently rewire dashboard
        // alert rules pointed at `code == 1001`.
        let event = AuthDecisionEvent(payload: payload(step: .classifierClassified))
        XCTAssertEqual(event.errorCode, 1001)
    }

    // MARK: - errorUserInfo forwards dashboardFields

    func testErrorUserInfo_includesAllDashboardFields() {
        let p = payload(
            step: .coordinatorRefreshCompleted,
            idpType: "saml",
            libraryUUID: "lib-cornell",
            statusCode: 401,
            problemDocType: "https://example/.../saml-session-expired",
            decision: "userCancelled",
            callSite: "Foo/bar"
        )
        let event = AuthDecisionEvent(payload: p)
        let userInfo = event.errorUserInfo
        XCTAssertEqual(userInfo["idp_type"] as? String, "saml")
        XCTAssertEqual(userInfo["library_uuid"] as? String, "lib-cornell")
        XCTAssertEqual(userInfo["status_code"] as? String, "401")
        XCTAssertEqual(userInfo["problem_doc_type"] as? String, "https://example/.../saml-session-expired")
        XCTAssertEqual(userInfo["decision"] as? String, "userCancelled")
        XCTAssertEqual(userInfo["step"] as? String, "coordinator.refresh.completed")
        XCTAssertEqual(userInfo["call_site"] as? String, "Foo/bar")
    }

    func testErrorUserInfo_includesNSLocalizedDescription_withStepAndDecision() {
        // Crashlytics defaults to NSLocalizedDescriptionKey for the row
        // label. We compose "step: decision" so the dashboard list view
        // tells you what happened at a glance without expanding userInfo.
        let p = payload(
            step: .coordinatorModalCancelled,
            idpType: "saml",
            libraryUUID: nil,
            statusCode: nil,
            problemDocType: nil,
            decision: "userCancelled",
            callSite: "X/Y"
        )
        let event = AuthDecisionEvent(payload: p)
        let userInfo = event.errorUserInfo
        XCTAssertEqual(userInfo[NSLocalizedDescriptionKey] as? String,
                       "coordinator.modal.cancelled: userCancelled")
    }

    func testErrorUserInfo_dropsAbsentFields() {
        // Nil status / problem doc / library UUID → keys MUST be omitted,
        // not emit as `"<nil>"` or empty string. Crashlytics dashboard
        // filters on raw values, so missing keys mean "any value"
        // — emitting "<nil>" would clobber that filter.
        let p = payload(
            step: .classifierClassified,
            idpType: "token",
            libraryUUID: nil,
            statusCode: nil,
            problemDocType: nil,
            decision: "networkError",
            callSite: "X/Y"
        )
        let event = AuthDecisionEvent(payload: p)
        let userInfo = event.errorUserInfo
        XCTAssertNil(userInfo["library_uuid"])
        XCTAssertNil(userInfo["status_code"])
        XCTAssertNil(userInfo["problem_doc_type"])
        XCTAssertEqual(userInfo["idp_type"] as? String, "token",
            "non-nil fields MUST still appear after the nil-drop pass")
    }

    // MARK: - Recorder smoke (no Crashlytics call — verifies SUT wires payload → event)

    func testProductionRecorder_constructsWithoutCrash() {
        // Real Crashlytics call would require Firebase init in a host app,
        // which test bundles don't have. This pins that the recorder can
        // be constructed and its `record(_:)` invocation doesn't crash
        // even when Firebase isn't running.
        let recorder = AuthDecisionRecorder()
        recorder.record(payload(step: .classifierClassified))
        // No assertion — survival is the test. Real emission asserts in
        // smoke testing via the Firebase dashboard.
    }

    // MARK: - Helpers

    private func payload(
        step: AuthDecisionStep,
        idpType: String = "unknown",
        libraryUUID: String? = nil,
        statusCode: Int? = nil,
        problemDocType: String? = nil,
        decision: String = "ok",
        callSite: String = "test",
        correlationID: UUID = UUID()
    ) -> AuthDecisionPayload {
        AuthDecisionPayload(
            step: step,
            idpType: idpType,
            libraryUUID: libraryUUID,
            statusCode: statusCode,
            problemDocType: problemDocType,
            decision: decision,
            callSite: callSite,
            correlationID: correlationID
        )
    }
}
