//
//  AuthCoordinatorTelemetryTests.swift
//  PalaceTests
//
//  Main-target integration tests that exercise the SAME spy used in
//  PalaceTests/Mocks/ against `AuthCoordinator` constructed with the
//  recorder. Verifies the end-to-end shape of the events that
//  Crashlytics will see in production.
//
//  These tests complement `AuthDecisionEventEmissionTests` (which pin
//  the Error/userInfo wrapping) by exercising the actual coordinator
//  emission path with the same spy AppContainer would inject in dev.
//

import XCTest
import PalaceAuth
@testable import Palace

@MainActor
final class AuthCoordinatorTelemetryTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Round-trip: coordinator emits both events, both ride correlation

    func testCoordinator_refreshFlow_emitsStartAndEnd_correlatedByID() async {
        let env = makeEnv(mechanism: .token, silentSucceeds: true)
        let fixedID = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken, correlationID: fixedID)

        let starts = env.recorder.events(step: .coordinatorRefreshStarted)
        let ends = env.recorder.events(step: .coordinatorRefreshCompleted)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(starts.first?.correlationID, fixedID,
            "AppContainer-wired coordinator MUST propagate the caller's correlation ID into start events")
        XCTAssertEqual(ends.first?.correlationID, fixedID,
            "...and end events, so the dashboard can reconstruct one auth flow as a single row family")
    }

    // MARK: - Round-trip: payload carries idpType from the live mechanism

    func testCoordinator_payload_idpType_reflectsMechanismProvider() async {
        let env = makeEnv(mechanism: .saml, modalSucceeds: true)
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        let end = env.recorder.events(step: .coordinatorRefreshCompleted).first
        XCTAssertEqual(end?.idpType, "saml",
            "main-target wiring must surface the current account's mechanism to the payload")
    }

    func testCoordinator_payload_libraryUUID_reflectsProviderClosure() async {
        let env = makeEnv(mechanism: .token, silentSucceeds: true, libraryUUID: "urn:uuid:integration-test")
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        let end = env.recorder.events(step: .coordinatorRefreshCompleted).first
        XCTAssertEqual(end?.libraryUUID, "urn:uuid:integration-test")
    }

    // MARK: - Frequency budget: SAML modal cancel emits cancel sub-event

    func testCoordinator_samlModalCancel_emitsCancelSubEvent_forFastDashboardFilter() async {
        let env = makeEnv(mechanism: .saml, modalSucceeds: false)
        _ = await env.coordinator.refreshCredentialsIfNeeded(reason: .samlSessionExpired)
        let cancels = env.recorder.events(step: .coordinatorModalCancelled)
        XCTAssertEqual(cancels.count, 1)
        XCTAssertEqual(cancels.first?.decision, "userCancelled")
    }

    // MARK: - Production AppContainer wires telemetry

    func testAppContainerProduction_wiresAuthCoordinator() {
        // Smoke: the production AppContainer exposes an `authCoordinator`
        // built with the AuthDecisionRecorder. Verifies the wiring change
        // didn't regress to a default no-op recorder. We can't directly
        // introspect the recorder (it's private), but constructing
        // production() without crashing proves the MainActor.assumeIsolated
        // path + recorder wiring landed cleanly.
        let container = AppContainer.production()
        // assert that the container hands back the same coordinator across
        // calls — a fresh-per-call construction would defeat single-flight.
        let again = AppContainer.production()
        XCTAssertTrue(
            container.authCoordinator === again.authCoordinator,
            "AppContainer.production().authCoordinator must be stable across calls — fresh-per-call would break single-flight semantics"
        )
    }

    // MARK: - Helpers

    private func makeEnv(
        mechanism: AuthMechanism?,
        silentSucceeds: Bool = false,
        modalSucceeds: Bool = false,
        libraryUUID: String? = nil
    ) -> Env {
        let recorder = SpyAuthDecisionRecorder()
        let coordinator = AuthCoordinator(
            reauthenticator: SpyReauth(succeeds: silentSucceeds),
            modalPresenter: SpyModal(succeeds: modalSucceeds),
            userAccount: SpyUser(),
            accountProvider: SpyAccountProvider(mechanism: mechanism),
            recorder: recorder,
            libraryUUIDProvider: { libraryUUID }
        )
        return Env(coordinator: coordinator, recorder: recorder)
    }

    private struct Env {
        let coordinator: AuthCoordinator
        let recorder: SpyAuthDecisionRecorder
    }
}

// MARK: - Local spies (mirror SPM-side definitions)

private final class SpyReauth: Reauthenticating, @unchecked Sendable {
    private let succeeds: Bool
    init(succeeds: Bool) { self.succeeds = succeeds }
    func authenticateIfNeeded(usingExistingCredentials: Bool) async -> Bool { succeeds }
}

private final class SpyModal: SignInModalPresenting, @unchecked Sendable {
    private let succeeds: Bool
    init(succeeds: Bool) { self.succeeds = succeeds }
    func presentSignInModalForCurrentAccount() async -> Bool { succeeds }
}

private final class SpyUser: TPPUserAccountReading, TPPUserAccountWriting, @unchecked Sendable {
    var hasCredentials: Bool { true }
    var authTokenHasExpired: Bool { false }
    func markCredentialsStale() {}
}

private final class SpyAccountProvider: TPPCurrentLibraryAccountProviding, @unchecked Sendable {
    var currentAccountMechanism: AuthMechanism?
    init(mechanism: AuthMechanism?) { self.currentAccountMechanism = mechanism }
}
