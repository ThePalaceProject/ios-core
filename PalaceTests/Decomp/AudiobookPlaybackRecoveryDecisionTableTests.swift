//
//  AudiobookPlaybackRecoveryDecisionTableTests.swift
//  PalaceTests
//
//  Wave 6 decomposition pin for `Palace/Audiobooks/AudiobookSessionManager.swift`
//  (god-class-decomposition-plan.md §3a-1 "Public API + Manager Binding →
//  orchestration decision logic → reducer", §5 fleet row "session-state
//  contract").
//
//  WHAT THIS PINS THAT NOTHING ELSE DID
//
//  The five playback-failure recovery predicates were each already unit-pinned
//  in isolation (`AudiobookLoadFailureSAMLReauthTests`,
//  `AudiobookBearerTokenRecoveryTests`, `AudiobookColdLoadRecoveryTests`,
//  `OverdriveFulfillmentTests`, `AudiobookVendorRecoveryContractTests`). None of
//  them reached the PRECEDENCE between the predicates, because the ordering
//  lived as a chain of early-returning `if` arms inside `handleManagerState` —
//  which `AudiobookSessionManager.swift` itself records as untestable:
//  "nothing in PalaceTests drives `handleManagerState`."
//
//  Precedence is where the consequential failures live: an OverDrive title whose
//  signed URL expired on its FIRST play satisfies both the OverDrive arm and the
//  cold-load arm, and which one wins decides whether the patron gets fresh
//  signed URLs or a silent re-open of the same dead URL. CLAUDE.md is explicit
//  that this is a table, not a set of scenarios: "states × events is finite and
//  enumerable; scenarios are not."
//
//  THE TABLE. `decide(_:)` is a linear precedence chain over five predicates, so
//  the enumeration is (a) each predicate alone → its own decision, (b) every
//  simultaneously-satisfiable PAIR → the higher one wins, (c) the one input that
//  splits a decision in two (`contentIsLocal` under the cold-load arm), and
//  (d) every terminal shape. Each `decide` case's `keepsPlayerLoading` is
//  asserted too, because that property replaces a `willRecover` disjunction that
//  was computed independently of the arm that fired — and the two do not agree
//  (see `testKeepsPlayerLoading_bearerTokenRefulfill_isFalse`).
//
//  SATISFIABILITY IS NOT SYMMETRIC WITH REALISM. Two of the pairs below need a
//  fixture no circulation manager would emit — a title that is both an OverDrive
//  distributor and a bearer-token acquisition. They are included and labelled
//  because the reducer accepts such an input and the ordering must still be
//  defined; they are ordering pins, not field scenarios.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace
#if FEATURE_OVERDRIVE
import OverdriveProcessor
#endif

@MainActor
final class AudiobookPlaybackRecoveryDecisionTableTests: XCTestCase {

    private var userAccount: TPPUserAccountMock!
    private var library: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        userAccount = TPPUserAccountMock()
        library = TPPLibraryAccountMock()
    }

    override func tearDown() {
        userAccount?.removeAll()
        userAccount = nil
        library = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Makes the account satisfy the SAML half of
    /// `shouldTriggerSAMLReauthForPlaybackFailure`.
    private func makeAccountSAMLWithCredentials() {
        userAccount._authDefinition = library.samlAuthentication
        userAccount._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
    }

    /// The auth-required signal the toolkit's OpenAccessPlayer emits on a 401.
    /// `extraUserInfo` lets one error ALSO carry an expired-entitlement status,
    /// which is what makes the SAML-vs-refulfill precedence pairs constructible.
    private func authRequiredError(extraUserInfo: [String: Any] = [:]) -> NSError {
        NSError(
            domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer",
            code: 5,
            userInfo: extraUserInfo
        )
    }

    private func httpError(_ status: Int) -> NSError {
        NSError(domain: "test.playback", code: 1, userInfo: ["httpStatusCode": status])
    }

    private func plainError() -> NSError {
        NSError(domain: "test.playback", code: 99, userInfo: [:])
    }

    private func bearerTokenBook() -> TPPBook {
        TPPBookMocker.mockBook(distributorType: .BearerToken)
    }

    private func plainBook() -> TPPBook {
        TPPBookMocker.mockBook(title: "Plain")
    }

    /// Every axis defaulted to "this predicate does NOT fire", so each test names
    /// only the axes it is varying and an unmentioned axis is provably inert.
    private func context(
        error: Error? = nil,
        book: TPPBook? = nil,
        isAwaitingContentDownload: Bool = false,
        overdriveAttempted: Bool = true,
        bearerAttempted: Bool = true,
        coldLoadAttempted: Bool = true,
        hasEverStartedPlayback: Bool = true,
        contentIsLocal: Bool = true
    ) -> AudiobookPlaybackFailureContext {
        AudiobookPlaybackFailureContext(
            error: error,
            book: book,
            userAccount: userAccount,
            isAwaitingContentDownload: isAwaitingContentDownload,
            overdriveRefulfillAlreadyAttempted: overdriveAttempted,
            bearerTokenRefulfillAlreadyAttempted: bearerAttempted,
            coldLoadReopenAlreadyAttempted: coldLoadAttempted,
            hasEverStartedPlayback: hasEverStartedPlayback,
            contentIsLocal: { contentIsLocal }
        )
    }

    // MARK: - (a) Each arm alone selects its own decision

    func testDecide_awaitingContentDownload_ignoresFollowOnFailure() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: plainError(), book: plainBook(), isAwaitingContentDownload: true))
        XCTAssertEqual(decision, .ignoreFollowOnFailure,
            "A failure arriving while the session is parked awaiting this book's content download is the streaming player's follow-on storm (PP-4542 A) and must be swallowed")
        XCTAssertEqual(decision.keepsPlayerLoading, false,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    func testDecide_samlAuthRequired_selectsSamlReauth() {
        makeAccountSAMLWithCredentials()
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: authRequiredError(), book: plainBook()))
        XCTAssertEqual(decision, .samlReauth)
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    func testDecide_bearerTokenEntitlementExpiry_selectsBearerTokenRefulfill() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: httpError(403), book: bearerTokenBook(), bearerAttempted: false))
        XCTAssertEqual(decision, .bearerTokenRefulfill)
        XCTAssertEqual(decision.keepsPlayerLoading, false,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    func testDecide_coldLoadWithContentOnDisk_selectsColdLoadReopen() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: plainError(), book: plainBook(),
                    coldLoadAttempted: false, hasEverStartedPlayback: false,
                    contentIsLocal: true))
        XCTAssertEqual(decision, .coldLoadReopen)
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    func testDecide_coldLoadWithContentStillDownloading_selectsAwaitThenReopen() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: plainError(), book: plainBook(),
                    coldLoadAttempted: false, hasEverStartedPlayback: false,
                    contentIsLocal: false))
        XCTAssertEqual(decision, .coldLoadAwaitContentThenReopen,
            "Re-opening the same not-yet-materialized package fails identically; the wait is the recovery (PP-4542 A)")
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    // MARK: - (b) Precedence between simultaneously-satisfied arms

    func testPrecedence_awaitingBeatsEveryOtherArm() {
        makeAccountSAMLWithCredentials()
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: authRequiredError(extraUserInfo: ["httpStatusCode": 410]),
                    book: bearerTokenBook(),
                    isAwaitingContentDownload: true,
                    overdriveAttempted: false, bearerAttempted: false,
                    coldLoadAttempted: false, hasEverStartedPlayback: false,
                    contentIsLocal: false))
        XCTAssertEqual(decision, .ignoreFollowOnFailure,
            "The follow-on-failure suppression is first in the chain: while a content wait is in flight NO recovery may start, or the wait races its own re-open")
        XCTAssertEqual(decision.keepsPlayerLoading, false,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    func testPrecedence_samlBeatsBearerTokenRefulfill() {
        makeAccountSAMLWithCredentials()
        // One error that is BOTH the OpenAccessPlayer auth-required signal and a
        // 410 expired-entitlement signal, on a bearer-token title.
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: authRequiredError(extraUserInfo: ["httpStatusCode": 410]),
                    book: bearerTokenBook(), bearerAttempted: false))
        XCTAssertEqual(decision, .samlReauth,
            "Stale credentials must be refreshed first — a re-fulfill made with the same expired session just re-fails")
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    func testPrecedence_samlBeatsColdLoadReopen() {
        makeAccountSAMLWithCredentials()
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: authRequiredError(), book: plainBook(),
                    coldLoadAttempted: false, hasEverStartedPlayback: false))
        XCTAssertEqual(decision, .samlReauth,
            "A silent re-open on stale SAML credentials hits the same 401 and burns the single cold-load attempt")
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    func testPrecedence_bearerTokenBeatsColdLoadReopen() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: httpError(410), book: bearerTokenBook(),
                    bearerAttempted: false,
                    coldLoadAttempted: false, hasEverStartedPlayback: false))
        XCTAssertEqual(decision, .bearerTokenRefulfill,
            "A first-play entitlement expiry needs a fresh manifest, not a re-open of the stale one")
        XCTAssertEqual(decision.keepsPlayerLoading, false,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

#if FEATURE_OVERDRIVE
    // `OverdriveDistributorKey` is an ObjC constant vended by OverdriveProcessor,
    // which only links under FEATURE_OVERDRIVE — hence the import here rather
    // than at file scope.
    private func overdriveBook(bearerTokenAcquisition: Bool = false) -> TPPBook {
        let type = bearerTokenAcquisition
            ? ContentTypeBearerToken
            : "application/vnd.overdrive.circulation.api+json;profile=audiobook"
        return TPPBook(
            acquisitions: [TPPOPDSAcquisition(
                relation: .generic,
                type: type,
                hrefURL: URL(string: "https://od.test/fulfill")!,
                indirectAcquisitions: [],
                availability: TPPOPDSAcquisitionAvailabilityUnlimited()
            )],
            authors: [], categoryStrings: [], distributor: OverdriveDistributorKey,
            identifier: UUID().uuidString, imageURL: nil, imageThumbnailURL: nil,
            published: Date(), publisher: "Test", subtitle: nil, summary: nil,
            title: "OD Fixture", updated: Date(), annotationsURL: nil, analyticsURL: nil,
            alternateURL: nil, relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil, contributors: [:],
            bookDuration: nil, imageCache: MockImageCache()
        )
    }

    func testDecide_overdriveSignedURLExpiry_selectsOverdriveRefulfill() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: httpError(410), book: overdriveBook(), overdriveAttempted: false))
        XCTAssertEqual(decision, .overdriveRefulfill)
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    func testPrecedence_samlBeatsOverdriveRefulfill() {
        makeAccountSAMLWithCredentials()
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: authRequiredError(extraUserInfo: ["httpStatusCode": 410]),
                    book: overdriveBook(), overdriveAttempted: false))
        XCTAssertEqual(decision, .samlReauth)
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    /// Synthetic overlap: no circulation manager emits an OverDrive-distributor
    /// title with a bearer-token acquisition. Included because the reducer
    /// accepts the input and the ordering must be defined — the OverDrive arm
    /// routes through the download centre's 302 header dance, which the generic
    /// bearer-token re-fulfill does not perform.
    func testPrecedence_overdriveBeatsBearerTokenRefulfill() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: httpError(410),
                    book: overdriveBook(bearerTokenAcquisition: true),
                    overdriveAttempted: false, bearerAttempted: false))
        XCTAssertEqual(decision, .overdriveRefulfill)
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    func testPrecedence_overdriveBeatsColdLoadReopen() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: httpError(410), book: overdriveBook(),
                    overdriveAttempted: false,
                    coldLoadAttempted: false, hasEverStartedPlayback: false))
        XCTAssertEqual(decision, .overdriveRefulfill,
            "A first-play signed-URL expiry needs fresh URLs; re-opening the same expired manifest fails identically")
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    /// The bound is per-arm, not shared: an exhausted OverDrive attempt must
    /// fall THROUGH to the cold-load arm rather than short-circuit the chain.
    func testPrecedence_overdriveExhausted_fallsThroughToColdLoadReopen() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: httpError(410), book: overdriveBook(),
                    overdriveAttempted: true,
                    coldLoadAttempted: false, hasEverStartedPlayback: false))
        XCTAssertEqual(decision, .coldLoadReopen)
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }
#endif

    /// Same fall-through property on the bearer-token arm.
    func testPrecedence_bearerExhausted_fallsThroughToColdLoadReopen() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: httpError(410), book: bearerTokenBook(),
                    bearerAttempted: true,
                    coldLoadAttempted: false, hasEverStartedPlayback: false))
        XCTAssertEqual(decision, .coldLoadReopen)
        XCTAssertEqual(decision.keepsPlayerLoading, true,
            "The decision and the state it publishes are one value — a cell that selects a recovery but publishes the wrong state is the divergence this reducer removes")
    }

    // MARK: - (c) Terminal shapes

    func testDecide_noArmApplies_midPlayback_isTerminalWithoutAlert() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: plainError(), book: plainBook(), hasEverStartedPlayback: true))
        XCTAssertEqual(decision, .terminal(dismissAndAlert: false),
            "A failure after playback started publishes the error but must NOT dismiss the player — the patron is mid-listen")
        XCTAssertEqual(decision.keepsPlayerLoading, false,
            "A terminal failure publishes .error, never the recovering .loading state")
    }

    func testDecide_coldLoadAlreadyAttempted_isTerminalWithAlert() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: plainError(), book: plainBook(),
                    coldLoadAttempted: true, hasEverStartedPlayback: false))
        XCTAssertEqual(decision, .terminal(dismissAndAlert: true),
            "A cold load that persisted past its one silent re-open dismisses the player and surfaces the unavailable alert")
        XCTAssertEqual(decision.keepsPlayerLoading, false,
            "A terminal failure publishes .error, never the recovering .loading state")
    }

    func testDecide_noBook_isTerminalWithoutAlert() {
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: plainError(), book: nil, hasEverStartedPlayback: false))
        XCTAssertEqual(decision, .terminal(dismissAndAlert: false),
            "With no current book there is nothing to dismiss or re-open")
        XCTAssertEqual(decision.keepsPlayerLoading, false,
            "A terminal failure publishes .error, never the recovering .loading state")
    }

    // MARK: - (d) keepsPlayerLoading for every decision

    func testKeepsPlayerLoading_recoveringArms_areTrue() {
        XCTAssertTrue(AudiobookPlaybackRecovery.samlReauth.keepsPlayerLoading)
        XCTAssertTrue(AudiobookPlaybackRecovery.overdriveRefulfill.keepsPlayerLoading)
        XCTAssertTrue(AudiobookPlaybackRecovery.coldLoadReopen.keepsPlayerLoading)
        XCTAssertTrue(AudiobookPlaybackRecovery.coldLoadAwaitContentThenReopen.keepsPlayerLoading)
    }

    func testKeepsPlayerLoading_terminal_isFalseForBothShapes() {
        XCTAssertFalse(AudiobookPlaybackRecovery.terminal(dismissAndAlert: true).keepsPlayerLoading)
        XCTAssertFalse(AudiobookPlaybackRecovery.terminal(dismissAndAlert: false).keepsPlayerLoading)
    }

    /// PINS A KNOWN DIVERGENCE, NOT A DESIRED BEHAVIOUR.
    ///
    /// `.bearerTokenRefulfill` publishes `.error` and then immediately re-opens,
    /// so a BiblioBoard / Unlimited Listens title whose entitlement expires
    /// mid-listen flashes the failure dialog the recovery then undoes — the
    /// error-then-recover flicker the loading state exists to prevent (PP-4800).
    /// The `willRecover` disjunction this property replaces read
    /// `SAML || OverDrive || coldLoad` and never gained a bearer-token term when
    /// 323-Cause-3 added that arm.
    ///
    /// Asserted false so the shipped behaviour is reproduced by this
    /// decomposition rather than silently changed inside it. Flipping the
    /// production value to `true` is the fix, and it fails exactly this test.
    func testKeepsPlayerLoading_bearerTokenRefulfill_isFalse() {
        XCTAssertFalse(AudiobookPlaybackRecovery.bearerTokenRefulfill.keepsPlayerLoading,
            "Reproduces the shipped willRecover disjunction, which omits the bearer-token arm")
        // Asserted through the real decision too, so the divergence is pinned
        // where it reaches production and not only on the enum in isolation.
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: httpError(403), book: bearerTokenBook(), bearerAttempted: false))
        XCTAssertEqual(decision, .bearerTokenRefulfill)
        XCTAssertFalse(decision.keepsPlayerLoading,
            "A BiblioBoard mid-listen entitlement expiry publishes .error and then re-opens — the PP-4800 flicker, reproduced not fixed here")
    }

    func testKeepsPlayerLoading_ignoreFollowOnFailure_isFalse() {
        XCTAssertFalse(AudiobookPlaybackRecovery.ignoreFollowOnFailure.keepsPlayerLoading,
            "The suppressed failure publishes no state at all; the book is already parked in .loading by the arm that started the wait")
        // The value is unobserved in production — the dispatch returns before
        // reading it — so this asserts the decision itself is what suppresses,
        // rather than a state flag doing the suppressing.
        let decision = AudiobookPlaybackRecoveryReducer.decide(
            context(error: plainError(), book: plainBook(), isAwaitingContentDownload: true,
                    coldLoadAttempted: false, hasEverStartedPlayback: false))
        XCTAssertEqual(decision, .ignoreFollowOnFailure,
            "Suppression wins even when the cold-load arm would otherwise fire")
    }
}
