//  AdobeActivationGenerationGateTests.swift
//
//  PP-5251: pins the connector-generation gate on `ensureDeviceActivated`.
//
//  The gate exists because `isUserAuthorized` is the signal that LIES across a
//  connector change: the Wipro binaries report an Adobe-era activation as
//  authorized and then fail every operation with `E_ACT_NOT_READY`. So "already
//  activated" has to mean "activated under THIS connector", not "the connector
//  says yes".

import XCTest
@testable import Palace

final class AdobeActivationGenerationGateTests: XCTestCase {

    /// In-memory account double. Records the activation write so a test can
    /// assert the generation lands WITH the identifiers rather than separately.
    private final class GenerationAccount: AdobeActivationAccount, @unchecked Sendable {
        private let lock = NSLock()
        private var _userID: String?
        private var _deviceID: String?
        private var _generation: Int?
        private var _licensor: [String: Any]?
        /// Every activation write, in order, as a triple. A pair of independent
        /// setters would show up here as two entries with a half-written record
        /// between them.
        private var _writes: [(userID: String, deviceID: String, generation: Int)] = []

        init(licensor: [String: Any]?,
             userID: String? = nil,
             deviceID: String? = nil,
             generation: Int? = nil) {
            self._licensor = licensor
            self._userID = userID
            self._deviceID = deviceID
            self._generation = generation
        }

        var userID: String? { lock.withLock { _userID } }
        var deviceID: String? { lock.withLock { _deviceID } }
        var licensor: [String: Any]? { lock.withLock { _licensor } }
        var adobeActivationConnectorGeneration: Int? { lock.withLock { _generation } }

        func setAdobeActivation(userID: String, deviceID: String, generation: Int) {
            lock.withLock {
                _userID = userID
                _deviceID = deviceID
                _generation = generation
                _writes.append((userID, deviceID, generation))
            }
        }

        func setLicensor(_ licensor: [String: Any]) { lock.withLock { _licensor = licensor } }

        var writes: [(userID: String, deviceID: String, generation: Int)] {
            lock.withLock { _writes }
        }
    }

    private var drm: TPPDRMAuthorizingMock!
    private var service: AdobeDRMService!

    // Computed, not stored: a stored static `[String: Any]` is global mutable
    // state that Swift 6 rejects as non-Sendable.
    private static var validLicensor: [String: Any] {
        ["vendor": "palace-vendor", "clientToken": "token-user|token-password"]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        drm = TPPDRMAuthorizingMock()
        service = AdobeDRMService(activationCoordinator: AdobeActivationCoordinator())
    }

    override func tearDownWithError() throws {
        drm.reset()
        drm = nil
        service = nil
        try super.tearDownWithError()
    }

    /// The activation write hops through `TPPMainThreadRun.asyncIfNeeded`, so it
    /// can land after `ensureDeviceActivated` returns. Poll rather than assert
    /// instantaneously — `AdobeActivationDedupTests` does the same for the
    /// identifiers, and this file's first version asserted immediately and
    /// failed for that reason, not because the write was missing.
    private func waitFor(_ what: String,
                         timeout: TimeInterval = 2.0,
                         _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Lets any already-dispatched main-thread work run, so that asserting the
    /// ABSENCE of a write distinguishes "never dispatched" from "not yet run".
    /// Without this, a test expecting no write passes vacuously.
    private func drainMainQueue() async {
        await MainActor.run {}
    }

    /// Counts how many times the authorizer CLOSURE was invoked — not how many
    /// times `authorize` was called. Resolving the closure reaches
    /// `NYPLADEPT.sharedInstance()`, which initialises the non-thread-safe
    /// RMSDK, so "did we ask the connector" and "did we construct it" are
    /// different questions and only the second one was ever observed.
    private let authorizerResolutions = AuthorizerResolutionCounter()

    final class AuthorizerResolutionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func record() { lock.withLock { _count += 1 } }
    }

    private func activate(_ account: GenerationAccount,
                          connectorGeneration: Int = AdobeConnectorGeneration.current) async throws {
        try await service.ensureDeviceActivated(
            authorizer: { [drm, authorizerResolutions] in
                authorizerResolutions.record()
                return drm
            },
            userAccount: account,
            isDRMAvailable: true,
            connectorGeneration: connectorGeneration
        )
    }

    // MARK: - The gate

    /// The defect this exists to prevent. The connector reports the device as
    /// authorized, so the pre-PP-5251 guard returned early and every later Adobe
    /// operation failed with `E_ACT_NOT_READY`.
    func testStaleGeneration_ReActivates_EvenThoughTheConnectorSaysAuthorized() async throws {
        drm.isUserAuthorizedReturnValue = true
        // One generation BELOW current — with current == 1 that is 0, a value
        // nothing writes. It stands for any recorded-but-mismatched generation;
        // the Adobe-era-on-Wipro cell proper is (1, 2), tabled in
        // testNeedsReactivation_EveryCombination. Distinct from an absent
        // marker, which is backfilled.
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "old-user",
                                        deviceID: "old-device",
                                        generation: AdobeConnectorGeneration.current - 1)

        try await activate(account)

        XCTAssertEqual(drm.authorizeCallCount, 1,
                       "an activation recorded under an older connector must be redone, "
                       + "however authorized isUserAuthorized reports it")
    }

    /// An install that activated before the marker existed — every 3.3.x install.
    ///
    /// It must KEEP the fast path while the connector is unchanged. Re-activating
    /// here would put every existing patron's first post-upgrade Adobe borrow
    /// through the full activation path, which needs a licensor whose client
    /// token expires after 60 minutes, and would fail borrows that previously
    /// succeeded. `AdobeConnectorGeneration.preMarker` carries the reasoning;
    /// `testNeedsReactivation_EveryCombination` pins the Wipro side, where the
    /// same absent marker does re-activate.
    func testAbsentGeneration_KeepsTheFastPath_WhileTheConnectorIsUnchanged() async throws {
        drm.isUserAuthorizedReturnValue = true
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "old-user",
                                        deviceID: "old-device",
                                        generation: nil)

        try await activate(account)

        XCTAssertEqual(drm.authorizeCallCount, 0,
                       "an unmarked activation is backfilled to the pre-marker "
                       + "generation, which equals current on this build")
    }

    /// The gate cell nothing covered: identifiers present, generation current,
    /// but the connector itself says the device is NOT authorized. Deleting the
    /// `isUserAuthorized` conjunct from the compound guard left the suite green
    /// without this, because every other false case has no identifiers.
    func testCurrentGenerationButConnectorSaysUnauthorized_ReActivates() async throws {
        drm.isUserAuthorizedReturnValue = false
        drm.authorizeShouldSucceed = true
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "user",
                                        deviceID: "device",
                                        generation: AdobeConnectorGeneration.current)

        try await activate(account)

        XCTAssertEqual(drm.authorizeCallCount, 1,
                       "a matching generation does not override the connector's own "
                       + "verdict that the device is not authorized")
    }

    /// The other half: the gate must not re-activate on every call once the
    /// device is activated under this connector, or the migration would spend an
    /// activation slot on every Adobe operation.
    func testCurrentGeneration_SkipsActivation() async throws {
        drm.isUserAuthorizedReturnValue = true
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "user",
                                        deviceID: "device",
                                        generation: AdobeConnectorGeneration.current)

        try await activate(account)

        XCTAssertEqual(drm.authorizeCallCount, 0,
                       "a device activated under the current connector is already activated")
    }

    // MARK: - The predicate's own guards

    /// Measured survivor before this existed: flipping
    /// `guard let userID, let deviceID else { return false }` to `return true`
    /// left every test green. Both tested call sites unwrap before calling, so
    /// the else branch never executed under test — and a device with no
    /// identifiers would have been reported usable, handing an already-known
    /// answer to the non-thread-safe RMSDK.
    func testNilIdentifiersAreNotUsable_AndDoNotEnterTheConnector() {
        XCTAssertFalse(drm.canUseRecordedActivation(
            userID: nil, deviceID: "device",
            recordedGeneration: AdobeConnectorGeneration.current))
        XCTAssertFalse(drm.canUseRecordedActivation(
            userID: "user", deviceID: nil,
            recordedGeneration: AdobeConnectorGeneration.current))
        XCTAssertFalse(drm.canUseRecordedActivation(
            userID: nil, deviceID: nil, recordedGeneration: nil))

        XCTAssertEqual(drm.isUserAuthorizedCallCount, 0,
                       "missing identifiers are decisive without asking the connector")
    }

    /// F3: the settling property, driven on ONE account instead of composed
    /// across two tests with a seeded intermediate. A write landing on the wrong
    /// field, or after the next gate read, keeps the composed pair green.
    func testOnAWiproBuild_ActivatingTwiceSettlesAfterTheFirst() async throws {
        drm.isUserAuthorizedReturnValue = true
        drm.authorizeShouldSucceed = true
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "old-user",
                                        deviceID: "old-device",
                                        generation: 1)

        try await activate(account, connectorGeneration: 2)
        await waitFor("the migrated generation to be recorded") {
            account.adobeActivationConnectorGeneration == 2
        }
        try await activate(account, connectorGeneration: 2)

        XCTAssertEqual(drm.authorizeCallCount, 1,
                       "the second operation must skip: a migration that re-activates "
                       + "every time spends an activation slot on each one")
    }

    /// The laziness invariant, which was documented in two comments and enforced
    /// by nothing. Inlining the optionals into the predicate call is
    /// boolean-identical — the predicate guards nils itself — so it compiles and
    /// leaves every other test green, while production resolves
    /// `NYPLADEPT.sharedInstance()` on every borrow for a library with no Adobe
    /// licensor. Measured survivor before this existed.
    func testNoIdentifiers_DoesNotEvenResolveTheAuthorizer() async throws {
        let account = GenerationAccount(licensor: Self.validLicensor)
        XCTAssertNil(account.userID)
        XCTAssertNil(account.deviceID)
        drm.authorizeShouldSucceed = true

        try await activate(account)

        XCTAssertEqual(authorizerResolutions.count, 1,
                       "the activation path resolves the authorizer exactly once, to "
                       + "authorize — not a second time for a gate decision the "
                       + "identifiers already settle")
    }

    /// The other direction: when identifiers exist the gate does resolve it, so
    /// the test above cannot be satisfied by never resolving at all.
    func testWithIdentifiers_TheGateResolvesTheAuthorizer() async throws {
        drm.isUserAuthorizedReturnValue = true
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "user",
                                        deviceID: "device",
                                        generation: AdobeConnectorGeneration.current)

        try await activate(account)

        XCTAssertGreaterThanOrEqual(authorizerResolutions.count, 1,
                                    "the gate must ask the connector when the "
                                    + "identifiers do not settle the question")
    }

    // MARK: - The account overload

    /// The three decision sites — `shouldSkipAdobeActivation`,
    /// `logInIfUserAuthorized` and `didSelectRead` — call the overload that
    /// takes the whole account, so the overload is now the only place
    /// identifiers and generation are paired. Substituting
    /// `AdobeConnectorGeneration.current` for the account's recorded value
    /// there would restore PP-5026 at all three at once, and no corpus lint can
    /// see inside a method body.
    func testTheAccountOverloadReadsTheAccountsRecordedGeneration() {
        drm.isUserAuthorizedReturnValue = true
        let adobeEra = GenerationAccount(licensor: Self.validLicensor,
                                         userID: "user",
                                         deviceID: "device",
                                         generation: 1)

        XCTAssertFalse(drm.canUseRecordedActivation(adobeEra, current: 2),
                       "an Adobe-era activation is not usable by a Wipro connector, "
                       + "however loudly the connector itself says authorized")
    }

    /// The other side of the same substitution: a device already migrated must
    /// stay on the fast path, or every Adobe operation spends an activation slot.
    func testTheAccountOverloadSkipsAnAlreadyMigratedAccount() {
        drm.isUserAuthorizedReturnValue = true
        let migrated = GenerationAccount(licensor: Self.validLicensor,
                                         userID: "user",
                                         deviceID: "device",
                                         generation: 2)

        XCTAssertTrue(drm.canUseRecordedActivation(migrated, current: 2))
    }

    /// The overload must not invent identifiers either: an account with a
    /// matching generation but no identifiers has nothing to reuse.
    func testTheAccountOverloadRejectsAnAccountWithoutIdentifiers() {
        drm.isUserAuthorizedReturnValue = true
        let empty = GenerationAccount(licensor: Self.validLicensor,
                                      generation: AdobeConnectorGeneration.current)

        XCTAssertFalse(drm.canUseRecordedActivation(empty))
        XCTAssertEqual(drm.isUserAuthorizedCallCount, 0,
                       "a decision already known must not enter the non-thread-safe RMSDK")
    }

    // MARK: - The connector swap, driven through the gate

    /// The case PP-5251 exists for, end to end rather than as pure logic.
    ///
    /// Every other gate test is written relative to `AdobeConnectorGeneration
    /// .current`, so all of them pass by construction once that constant moves
    /// to 2 — nothing would have failed at the moment the migration was supposed
    /// to start working. Injecting the generation is what makes the Wipro
    /// behaviour assertable before the connector is swapped.
    func testOnAWiproBuild_AnUnmarkedActivationReActivates() async throws {
        drm.isUserAuthorizedReturnValue = true
        drm.authorizeShouldSucceed = true
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "old-user",
                                        deviceID: "old-device",
                                        generation: nil)

        try await activate(account, connectorGeneration: 2)

        XCTAssertEqual(drm.authorizeCallCount, 1,
                       "an activation predating the marker must be redone once the "
                       + "connector generation moves past preMarker")
    }

    /// The Adobe-era-on-Wipro cell proper: recorded 1, running 2.
    func testOnAWiproBuild_AnAdobeEraActivationReActivates() async throws {
        drm.isUserAuthorizedReturnValue = true
        drm.authorizeShouldSucceed = true
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "old-user",
                                        deviceID: "old-device",
                                        generation: 1)

        try await activate(account, connectorGeneration: 2)

        XCTAssertEqual(drm.authorizeCallCount, 1)
    }

    /// And it settles: once re-activated under 2, a later operation skips. Without
    /// this the migration could re-activate on every Adobe operation forever,
    /// spending a slot each time.
    func testOnAWiproBuild_AnAlreadyMigratedDeviceSkips() async throws {
        drm.isUserAuthorizedReturnValue = true
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "user",
                                        deviceID: "device",
                                        generation: 2)

        try await activate(account, connectorGeneration: 2)

        XCTAssertEqual(drm.authorizeCallCount, 0)
    }

    /// The write must stamp the generation the run was gated on, or the gate
    /// never settles: re-activating under 2 while recording 1 re-fires forever.
    func testOnAWiproBuild_ActivationStampsTheRunningGeneration() async throws {
        drm.isUserAuthorizedReturnValue = false
        drm.authorizeShouldSucceed = true
        let account = GenerationAccount(licensor: Self.validLicensor)

        try await activate(account, connectorGeneration: 2)

        await waitFor("the activation to be recorded") {
            account.adobeActivationConnectorGeneration != nil
        }
        XCTAssertEqual(account.adobeActivationConnectorGeneration, 2,
                       "stamping the constant instead of the running generation "
                       + "would leave the device permanently unmigrated")
    }

    /// The ordering QA found unasserted: a stale generation must be decided
    /// WITHOUT entering the connector, which is Adobe's non-thread-safe RMSDK.
    /// Swapping the two conditions leaves every other assertion in this file
    /// green, so only a call counter can pin it.
    func testStaleGeneration_DecidesWithoutEnteringTheConnector() async throws {
        drm.isUserAuthorizedReturnValue = true
        drm.authorizeShouldSucceed = true
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "old-user",
                                        deviceID: "old-device",
                                        generation: 1)

        try await activate(account, connectorGeneration: 2)

        XCTAssertEqual(drm.isUserAuthorizedCallCount, 0,
                       "a generation mismatch is already decisive; asking the "
                       + "connector first would enter the RMSDK for nothing")
        XCTAssertEqual(drm.authorizeCallCount, 1)
    }

    /// And the other side: when the generation matches, the connector IS asked.
    /// Without this the test above is satisfied by never calling it at all.
    func testMatchingGeneration_DoesAskTheConnector() async throws {
        drm.isUserAuthorizedReturnValue = true
        let account = GenerationAccount(licensor: Self.validLicensor,
                                        userID: "user",
                                        deviceID: "device",
                                        generation: AdobeConnectorGeneration.current)

        try await activate(account)

        XCTAssertEqual(drm.isUserAuthorizedCallCount, 1,
                       "a matching generation is not sufficient on its own")
    }

    // MARK: - The write

    /// Closes the loop. An activation that records no generation is backfilled
    /// to `preMarker`, so once `current` moves past it the gate above would
    /// re-activate on every operation and never be satisfied.
    func testSuccessfulActivation_RecordsTheCurrentGeneration() async throws {
        drm.isUserAuthorizedReturnValue = false
        drm.authorizeShouldSucceed = true
        let account = GenerationAccount(licensor: Self.validLicensor)

        try await activate(account)

        await waitFor("the activation to be recorded") {
            account.adobeActivationConnectorGeneration != nil
        }
        XCTAssertEqual(account.adobeActivationConnectorGeneration,
                       AdobeConnectorGeneration.current,
                       "activation must stamp the connector that performed it")
    }

    /// The identifiers and the generation are one record. Written separately, a
    /// crash in between leaves a device that looks activated with no connector
    /// recorded.
    func testActivationWritesTheIdentifiersAndGenerationTogether() async throws {
        drm.isUserAuthorizedReturnValue = false
        drm.authorizeShouldSucceed = true
        let account = GenerationAccount(licensor: Self.validLicensor)

        try await activate(account)

        await waitFor("the activation record") { !account.writes.isEmpty }
        XCTAssertEqual(account.writes.count, 1,
                       "the activation record must be written once, not as separate fields")
        let write = try XCTUnwrap(account.writes.first)
        XCTAssertFalse(write.userID.isEmpty)
        XCTAssertFalse(write.deviceID.isEmpty)
        XCTAssertEqual(write.generation, AdobeConnectorGeneration.current)
    }

    /// A failed activation must not stamp a generation: that would mark the
    /// device migrated when it is not, and the gate would never retry.
    func testFailedActivation_DoesNotRecordAGeneration() async throws {
        drm.isUserAuthorizedReturnValue = false
        drm.authorizeShouldSucceed = false
        let account = GenerationAccount(licensor: Self.validLicensor)

        do {
            try await activate(account)
            XCTFail("a rejected activation must throw")
        } catch {
            // expected
        }

        // Drain first: without it this passes whether no write was dispatched or
        // one simply has not run yet, which is not the claim being made.
        await drainMainQueue()

        XCTAssertNil(account.adobeActivationConnectorGeneration,
                     "a device that failed to activate has not been activated under "
                     + "this connector")
        XCTAssertTrue(account.writes.isEmpty)
    }
}
