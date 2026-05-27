//
//  AuthTelemetryEmissionTests.swift
//  PalaceAuthTests
//
//  Tests that pin the `AuthCoordinator` emission shape: which steps fire
//  for which scenarios, correlation-ID propagation, single-flight event
//  count, and the special SAML cookie / token-refresh helpers.
//
//  Complement to `AuthDecisionPayloadTests` which pins the classifier
//  side. Together these prove the 6 surface points from the contract
//  emit exactly once per logical decision.
//

import XCTest
@testable import PalaceAuth

final class AuthTelemetryEmissionTests: XCTestCase {

    // MARK: - Refresh start + end emission

    func testRefresh_emitsStartAndEnd_withSameCorrelationID() async {
        let env = TestEnv(mechanism: .token, silentSucceeds: true)
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken, correlationID: id)

        let start = env.recorder.events(step: .coordinatorRefreshStarted)
        let end = env.recorder.events(step: .coordinatorRefreshCompleted)
        XCTAssertEqual(start.count, 1, "expected one refresh-started event")
        XCTAssertEqual(end.count, 1, "expected one refresh-completed event")
        XCTAssertEqual(start.first?.correlationID, id)
        XCTAssertEqual(end.first?.correlationID, id,
            "the refresh start + end events MUST share the caller's correlation ID")
    }

    func testRefresh_endEvent_decisionIsSuccess_onSilentSuccess() async {
        let env = TestEnv(mechanism: .token, silentSucceeds: true)
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        let end = env.recorder.events(step: .coordinatorRefreshCompleted).first
        XCTAssertEqual(end?.decision, "success")
    }

    func testRefresh_endEvent_decisionIsUserCancelled_onModalCancel() async {
        let env = TestEnv(mechanism: .saml, modalSucceeds: false)
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        let end = env.recorder.events(step: .coordinatorRefreshCompleted).first
        XCTAssertEqual(end?.decision, "userCancelled")
    }

    func testRefresh_endEvent_decisionIsNoActiveAccount_whenAccountNil() async {
        let env = TestEnv(mechanism: nil)
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        let end = env.recorder.events(step: .coordinatorRefreshCompleted).first
        XCTAssertEqual(end?.decision, "noActiveAccount",
            "no-account branch must emit a completion event with the right decision string")
        XCTAssertEqual(end?.idpType, "unknown",
            "nil mechanism → idpType 'unknown' on the completion event")
        // The no-account branch short-circuits before the start event.
        XCTAssertEqual(env.recorder.events(step: .coordinatorRefreshStarted).count, 0)
    }

    func testRefresh_endEvent_decisionIsRefreshAlreadyFailed_insideCooldown() async {
        let env = TestEnv(mechanism: .saml, modalSucceeds: false)
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        env.recorder.clear()

        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        let end = env.recorder.events(step: .coordinatorRefreshCompleted).first
        XCTAssertEqual(end?.decision, "refreshAlreadyFailed",
            "cooldown short-circuit must still surface a completion event so the dashboard sees the rate of cooldown hits")
        XCTAssertEqual(env.recorder.events(step: .coordinatorRefreshStarted).count, 0,
            "cooldown branch must NOT emit a refresh-started event — only the completion")
    }

    // MARK: - Silent refresh + modal cancel sub-events

    func testRefresh_silentSuccess_emitsSilentRefreshEvent_success() async {
        let env = TestEnv(mechanism: .token, silentSucceeds: true)
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        let silent = env.recorder.events(step: .coordinatorSilentRefresh)
        XCTAssertEqual(silent.count, 1, "silent path must emit one silent-refresh event")
        XCTAssertEqual(silent.first?.decision, "success")
    }

    func testRefresh_silentFailureFallsBackToModal_emitsBothEvents() async {
        let env = TestEnv(mechanism: .token, silentSucceeds: false, modalSucceeds: true)
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        let silent = env.recorder.events(step: .coordinatorSilentRefresh)
        let modalCancels = env.recorder.events(step: .coordinatorModalCancelled)
        let end = env.recorder.events(step: .coordinatorRefreshCompleted).first
        XCTAssertEqual(silent.count, 1)
        XCTAssertEqual(silent.first?.decision, "failure")
        XCTAssertEqual(modalCancels.count, 0,
            "modal succeeded → no cancel sub-event should fire")
        XCTAssertEqual(end?.decision, "success")
    }

    func testRefresh_modalCancelled_emitsCancelSubEvent() async {
        let env = TestEnv(mechanism: .saml, modalSucceeds: false)
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        let cancels = env.recorder.events(step: .coordinatorModalCancelled)
        XCTAssertEqual(cancels.count, 1,
            "user-cancelled modal must emit exactly one cancel sub-event for fast dashboard filtering")
        XCTAssertEqual(cancels.first?.decision, "userCancelled")
        XCTAssertEqual(cancels.first?.idpType, "saml")
    }

    // MARK: - Single-flight: two concurrent callers, NOT four events

    func testRefresh_singleFlight_emitsTwoEvents_NotFour() async {
        // Frequency budget per contract: "single-flighted; concurrent
        // callers join the in-flight task". The instrumentation must
        // respect that — two callers should produce ONE start + ONE end
        // event, not two pairs.
        let env = TestEnv(mechanism: .token, silentSucceeds: true)

        async let first = env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        async let second = env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        _ = await (first, second)

        let starts = env.recorder.events(step: .coordinatorRefreshStarted)
        let ends = env.recorder.events(step: .coordinatorRefreshCompleted)
        XCTAssertEqual(starts.count, 1,
            "single-flight join must emit ONE refresh-started, not one per concurrent caller (frequency budget)")
        XCTAssertEqual(ends.count, 1,
            "single-flight join must emit ONE refresh-completed; the joined caller does not get a duplicate completion event")
    }

    // MARK: - Library UUID propagation

    func testRefresh_payloadCarriesLibraryUUID_fromProvider() async {
        let env = TestEnv(
            mechanism: .saml,
            modalSucceeds: true,
            libraryUUID: "urn:uuid:cornell-shibboleth"
        )
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        let end = env.recorder.events(step: .coordinatorRefreshCompleted).first
        XCTAssertEqual(end?.libraryUUID, "urn:uuid:cornell-shibboleth")
    }

    // MARK: - SAML cookie validation helper

    func testRecordSAMLCookieValidationFailure_emitsOneEvent() async {
        let env = TestEnv(mechanism: .saml)
        await env.coordinator.recordSAMLCookieValidationFailure()
        let events = env.recorder.events(step: .samlCookieValidationFailed)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.idpType, "saml")
        XCTAssertEqual(events.first?.decision, "reauthRequired.samlSessionExpired")
    }

    // MARK: - Token refresh completion helper

    func testRecordTokenRefreshCompleted_success_emitsEvent_withStatusCode() async {
        let env = TestEnv(mechanism: .token)
        await env.coordinator.recordTokenRefreshCompleted(succeeded: true, statusCode: 200)
        let events = env.recorder.events(step: .tokenRefreshCompleted)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.decision, "success")
        XCTAssertEqual(events.first?.statusCode, 200)
        XCTAssertEqual(events.first?.idpType, "token")
    }

    func testRecordTokenRefreshCompleted_failure_emitsEvent_withFailureStatus() async {
        let env = TestEnv(mechanism: .token)
        await env.coordinator.recordTokenRefreshCompleted(succeeded: false, statusCode: 401)
        let events = env.recorder.events(step: .tokenRefreshCompleted)
        XCTAssertEqual(events.first?.decision, "failure")
        XCTAssertEqual(events.first?.statusCode, 401)
    }

    // MARK: - Sign-out emits no telemetry (out of swarm scope)

    func testSignOut_emitsNoCoordinatorEvents() async {
        // Sign-out is explicit OFF-LIMITS per the swarm contract.
        // The coordinator's `signOut` only marks credentials stale; it
        // must NOT emit telemetry that would clutter the auth-decision
        // dashboard with sign-out noise.
        let env = TestEnv(mechanism: .saml)
        await env.coordinator.signOut()
        XCTAssertEqual(env.recorder.recorded.count, 0,
            "sign-out is explicitly out of scope; it must not emit any AuthDecision events")
    }
}

// MARK: - Test environment

private struct TestEnv {
    let coordinator: AuthCoordinator
    let recorder: SpyAuthDecisionRecorder

    init(
        mechanism: AuthMechanism?,
        silentSucceeds: Bool = false,
        modalSucceeds: Bool = false,
        libraryUUID: String? = nil
    ) {
        let recorder = SpyAuthDecisionRecorder()
        self.recorder = recorder
        self.coordinator = AuthCoordinator(
            reauthenticator: SpyReauthenticator(succeeds: silentSucceeds),
            modalPresenter: SpyModalPresenter(succeeds: modalSucceeds),
            userAccount: SpyUserAccount(),
            accountProvider: SpyAccountProvider(mechanism: mechanism),
            recorder: recorder,
            libraryUUIDProvider: { libraryUUID }
        )
    }
}

// MARK: - Spies (local; mirror the AuthCoordinatorTests spies)

private final class SpyAuthDecisionRecorder: AuthDecisionRecording, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpyAuthDecisionRecorder")
    private var _recorded: [AuthDecisionPayload] = []

    var recorded: [AuthDecisionPayload] { queue.sync { _recorded } }

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

private final class SpyReauthenticator: Reauthenticating, @unchecked Sendable {
    private let succeeds: Bool
    init(succeeds: Bool) { self.succeeds = succeeds }
    func authenticateIfNeeded(usingExistingCredentials: Bool) async -> Bool { succeeds }
}

private final class SpyModalPresenter: SignInModalPresenting, @unchecked Sendable {
    private let succeeds: Bool
    init(succeeds: Bool) { self.succeeds = succeeds }
    func presentSignInModalForCurrentAccount() async -> Bool { succeeds }
}

private final class SpyUserAccount: TPPUserAccountReading, TPPUserAccountWriting, @unchecked Sendable {
    var hasCredentials: Bool { true }
    var authTokenHasExpired: Bool { false }
    func markCredentialsStale() {}
}

private final class SpyAccountProvider: TPPCurrentLibraryAccountProviding, @unchecked Sendable {
    var currentAccountMechanism: AuthMechanism?
    init(mechanism: AuthMechanism?) { self.currentAccountMechanism = mechanism }
}
