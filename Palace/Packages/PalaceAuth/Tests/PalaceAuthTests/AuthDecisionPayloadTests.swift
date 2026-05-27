//
//  AuthDecisionPayloadTests.swift
//  PalaceAuthTests
//
//  Tests that exercise `AuthDecisionPayload` emission shape from the
//  `AuthErrorClassifier` and `AuthCoordinator` seams. These tests prove:
//
//  1. Each instrumented surface point emits exactly one payload per call.
//  2. The payload fields (idp, library, status, decision, correlation,
//     callSite) are populated from the right sources.
//  3. The decision string mapping is stable — Crashlytics dashboard
//     filters rely on these strings being literal.
//  4. `dashboardFields` produces a flat dictionary suitable for the main
//     target's `errorUserInfo` (no nested keys, absent fields dropped).
//
//  Spy lives at the bottom of this file so PalaceAuthTests stays
//  self-contained — `PalaceTests/Mocks/SpyAuthDecisionRecorder.swift` is
//  the main-target equivalent for the Xcode-bundle tests.
//

import XCTest
import PalaceCatalog
@testable import PalaceAuth

final class AuthDecisionPayloadTests: XCTestCase {

    private let testURL = URL(string: "https://gorgon.palaceproject.io/library/loans")!

    // MARK: - Classifier emission shape

    func testClassifier_emitsExactlyOneEventPerCall() {
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)

        _ = classifier.classify(
            response: httpResponse(status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )

        XCTAssertEqual(spy.recorded.count, 1,
            "classifier MUST emit exactly one event per classify call, not zero, not two")
    }

    func testClassifier_emitsZeroEventsBeforeCall() {
        let spy = SpyAuthDecisionRecorder()
        _ = AuthErrorClassifier(recorder: spy)
        XCTAssertEqual(spy.recorded.count, 0,
            "construction MUST NOT emit — only classify() emits")
    }

    func testClassifier_payloadCarriesStatusCode() {
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)
        _ = classifier.classify(
            response: httpResponse(status: 503),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(spy.recorded.first?.statusCode, 503)
    }

    func testClassifier_payloadStatusCodeIsNil_forNetworkError() {
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)
        _ = classifier.classify(
            response: nil,
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertNil(spy.recorded.first?.statusCode,
            "nil response → no HTTP status; payload statusCode must be nil")
        XCTAssertEqual(spy.recorded.first?.decision, "networkError")
    }

    func testClassifier_payloadCarriesProblemDocType() {
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)
        // The classifier's recoverableReason() pattern is "/auth/recoverable/saml/"
        // — the recovery category lives in the URI path, NOT the URI fragment.
        let typeURI = "http://palaceproject.io/terms/problem/auth/recoverable/saml/session-expired"
        let doc = problemDoc(type: typeURI)
        _ = classifier.classify(
            response: httpResponse(status: 401, mime: "application/problem+json"),
            problemDocument: doc,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(spy.recorded.first?.problemDocType, typeURI,
            "raw problem-doc type URI must be forwarded verbatim to the payload")
        XCTAssertEqual(spy.recorded.first?.decision,
            "reauthRequired.samlSessionExpired",
            "problem-doc type must drive the decision string mapping")
    }

    func testClassifier_idpType_isUnknown_whenNoMechanismProvider() {
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)
        _ = classifier.classify(
            response: httpResponse(status: 200),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(spy.recorded.first?.idpType, "unknown",
            "no mechanism provider → idpType must default to 'unknown', not empty")
    }

    func testClassifier_idpType_populatedFromMechanismProvider() {
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(
            recorder: spy,
            mechanismProvider: { .saml }
        )
        _ = classifier.classify(
            response: httpResponse(status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(spy.recorded.first?.idpType, "saml")
    }

    func testClassifier_libraryUUID_populatedFromProvider() {
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(
            recorder: spy,
            libraryUUIDProvider: { "urn:uuid:lib-123" }
        )
        _ = classifier.classify(
            response: httpResponse(status: 200),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(spy.recorded.first?.libraryUUID, "urn:uuid:lib-123")
    }

    func testClassifier_callSite_defaultsToFileID() {
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)
        _ = classifier.classify(
            response: httpResponse(status: 200),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        // #fileID is "PalaceAuthTests/AuthDecisionPayloadTests.swift" from
        // this caller (the default propagates from the test file).
        XCTAssertTrue(
            spy.recorded.first?.callSite.contains("AuthDecisionPayloadTests") ?? false,
            "callSite defaults to caller's #fileID; expected to contain the test file name, got \(spy.recorded.first?.callSite ?? "nil")"
        )
    }

    func testClassifier_callSite_overridable_atCallSite() {
        // Module C callers (TPPNetworkResponder, etc.) pass their own
        // call-site string so the dashboard can pivot on the actual
        // consumer rather than the test's #fileID.
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)
        _ = classifier.classify(
            response: httpResponse(status: 200),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL,
            callSite: "TPPNetworkResponder/handleResponse"
        )
        XCTAssertEqual(spy.recorded.first?.callSite, "TPPNetworkResponder/handleResponse")
    }

    func testClassifier_correlationID_overridable() {
        // Coordinators that pre-allocate a correlation ID pass it in so
        // the classifier event and the coordinator events share the ID.
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)
        let fixedID = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        _ = classifier.classify(
            response: httpResponse(status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL,
            correlationID: fixedID
        )
        XCTAssertEqual(spy.recorded.first?.correlationID, fixedID)
    }

    func testClassifier_correlationID_freshPerCall_ifNotPassed() {
        // Without an injected ID, every call gets a unique correlation
        // so unrelated 401s aren't accidentally grouped on the dashboard.
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)
        _ = classifier.classify(response: httpResponse(status: 401),
                                problemDocument: nil, body: nil, originalRequestURL: testURL)
        _ = classifier.classify(response: httpResponse(status: 401),
                                problemDocument: nil, body: nil, originalRequestURL: testURL)
        XCTAssertEqual(spy.recorded.count, 2)
        XCTAssertNotEqual(spy.recorded[0].correlationID, spy.recorded[1].correlationID,
            "fresh classifier calls without an injected ID must produce distinct correlations")
    }

    func testClassifier_payloadTimestamp_isRecent() {
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)
        let before = Date()
        _ = classifier.classify(response: httpResponse(status: 200),
                                problemDocument: nil, body: nil, originalRequestURL: testURL)
        let after = Date()
        guard let stamp = spy.recorded.first?.timestamp else {
            return XCTFail("expected payload with timestamp")
        }
        XCTAssertGreaterThanOrEqual(stamp, before)
        XCTAssertLessThanOrEqual(stamp, after)
    }

    // MARK: - Decision string mapping (Crashlytics dashboard contract)

    func testDecisionString_ok() {
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .ok), "ok")
    }

    func testDecisionString_reauthRequired_eachReason() {
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .reauthRequired(reason: .expiredToken)),
                       "reauthRequired.expiredToken")
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .reauthRequired(reason: .invalidCredentials)),
                       "reauthRequired.invalidCredentials")
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .reauthRequired(reason: .samlSessionExpired)),
                       "reauthRequired.samlSessionExpired")
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .reauthRequired(reason: .oidcRefreshFailed)),
                       "reauthRequired.oidcRefreshFailed")
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .reauthRequired(reason: .unknown401)),
                       "reauthRequired.unknown401")
    }

    func testDecisionString_forbidden_eachReason() {
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .forbidden(reason: .licenseExpired)),
                       "forbidden.licenseExpired")
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .forbidden(reason: .geoRestriction)),
                       "forbidden.geoRestriction")
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .forbidden(reason: .accountSuspended)),
                       "forbidden.accountSuspended")
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .forbidden(reason: .contentProtected)),
                       "forbidden.contentProtected")
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .forbidden(reason: .unknown403)),
                       "forbidden.unknown403")
    }

    func testDecisionString_serverError_carriesStatus() {
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .serverError(status: 503)),
                       "serverError.503")
    }

    func testDecisionString_networkError() {
        XCTAssertEqual(AuthDecisionPayload.decisionString(for: .networkError),
                       "networkError")
    }

    func testIdpString_eachMechanism() {
        XCTAssertEqual(AuthDecisionPayload.idpString(for: .basic), "basic")
        XCTAssertEqual(AuthDecisionPayload.idpString(for: .token), "token")
        XCTAssertEqual(AuthDecisionPayload.idpString(for: .oauthIntermediary), "oauth")
        XCTAssertEqual(AuthDecisionPayload.idpString(for: .saml), "saml")
        XCTAssertEqual(AuthDecisionPayload.idpString(for: .oidc), "oidc")
        XCTAssertEqual(AuthDecisionPayload.idpString(for: nil), "unknown")
    }

    // MARK: - Dashboard fields (Crashlytics userInfo contract)

    func testDashboardFields_dropsNilStatusCode() {
        let payload = AuthDecisionPayload(
            step: .classifierClassified,
            idpType: "saml",
            libraryUUID: "lib-1",
            statusCode: nil,
            problemDocType: nil,
            decision: "networkError",
            callSite: "X/Y",
            correlationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let fields = payload.dashboardFields
        XCTAssertNil(fields["status_code"],
            "nil status must drop the key entirely so dashboard filters don't show <nil>")
        XCTAssertNil(fields["problem_doc_type"])
        XCTAssertEqual(fields["library_uuid"], "lib-1")
        XCTAssertEqual(fields["decision"], "networkError")
        XCTAssertEqual(fields["step"], "classifier.classified")
        XCTAssertEqual(fields["call_site"], "X/Y")
        XCTAssertEqual(fields["correlation_id"], "00000000-0000-0000-0000-000000000001")
        XCTAssertNotNil(fields["timestamp_iso"], "timestamp_iso must always be present")
    }

    func testDashboardFields_emitsAllPresentFields() {
        let payload = AuthDecisionPayload(
            step: .coordinatorRefreshCompleted,
            idpType: "saml",
            libraryUUID: "lib-cornell",
            statusCode: 401,
            problemDocType: "https://example/.../saml-session-expired",
            decision: "success",
            callSite: "AuthCoordinator/refreshCredentialsIfNeeded",
            correlationID: UUID()
        )
        let fields = payload.dashboardFields
        XCTAssertEqual(fields["status_code"], "401")
        XCTAssertEqual(fields["problem_doc_type"], "https://example/.../saml-session-expired")
        XCTAssertEqual(fields["library_uuid"], "lib-cornell")
        XCTAssertEqual(fields["idp_type"], "saml")
        XCTAssertEqual(fields["step"], "coordinator.refresh.completed")
        XCTAssertEqual(fields["decision"], "success")
    }

    // MARK: - Helpers

    private func httpResponse(status: Int, mime: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let mime { headers["Content-Type"] = mime }
        return HTTPURLResponse(
            url: testURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func problemDoc(type: String) -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": type,
            "title": "Test",
            "status": 401
        ])
    }
}

// MARK: - Spy

/// Records every payload the SUT submits. Test-local; the main-target
/// equivalent (`SpyAuthDecisionRecorder.swift` under PalaceTests/Mocks/)
/// is the version used by AppContainer-tier tests.
private final class SpyAuthDecisionRecorder: AuthDecisionRecording, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpyAuthDecisionRecorder")
    private var _recorded: [AuthDecisionPayload] = []

    var recorded: [AuthDecisionPayload] { queue.sync { _recorded } }

    func record(_ payload: AuthDecisionPayload) {
        queue.sync { _recorded.append(payload) }
    }
}
