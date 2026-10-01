//  AudiobookPlaybackRecoveryDecisionTableTests.swift
//
//  Pins precedence among the five playback-failure recovery predicates in
//  `decide(_:)` and the published `willRecover` (`SAML || OverDrive || coldLoad`);
//  precedence decides, for example, whether an expired OverDrive URL gets fresh
//  URLs or a re-open. Expected values are derived by hand from
//  `AudiobookSessionManager+ContentOpenPolicy.swift`. The OverDrive + bearer-token
//  pair is not a field scenario; it pins ordering for an accepted input.

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

    /// Unwraps a published outcome. A suppressed outcome carries no published
    /// state at all, so every non-suppression cell must land here.
    private func published(
        _ context: AudiobookPlaybackFailureContext
    ) -> (keepsPlayerLoading: Bool, recovery: AudiobookPlaybackRecovery)? {
        guard case .publish(let keepsPlayerLoading, let recovery) =
                AudiobookPlaybackRecoveryReducer.decide(context) else {
            return nil
        }
        return (keepsPlayerLoading, recovery)
    }

    // MARK: - (a) Each arm alone selects its own recovery

    func testDecide_awaitingContentDownload_suppressesTheFailure() {
        let outcome = AudiobookPlaybackRecoveryReducer.decide(
            context(error: plainError(), book: plainBook(), isAwaitingContentDownload: true))
        XCTAssertEqual(outcome, .suppressFollowOnFailure,
            "A failure arriving while the session is parked awaiting this book's content download is the streaming player's follow-on storm (PP-4542 A) and must be swallowed")
        XCTAssertNil(published(context(error: plainError(), book: plainBook(), isAwaitingContentDownload: true)),
            "Suppression publishes no state at all — the book is already held in .loading by the arm that started the wait")
    }

    func testDecide_samlAuthRequired_selectsSamlReauth() throws {
        makeAccountSAMLWithCredentials()
        let out = try XCTUnwrap(published(
            context(error: authRequiredError(), book: plainBook())))
        XCTAssertEqual(out.recovery, .samlReauth)
        // SAML term true; OverDrive false (not an OverDrive title); coldLoad
        // false (hasEverStartedPlayback defaults true). Disjunction: true.
        XCTAssertTrue(out.keepsPlayerLoading,
            "The SAML term of the shipped disjunction holds, so the session shows the loading shell while the credential refresh runs")
    }

    func testDecide_bearerTokenEntitlementExpiry_selectsBearerTokenRefulfill() throws {
        let out = try XCTUnwrap(published(
            context(error: httpError(403), book: bearerTokenBook(), bearerAttempted: false)))
        XCTAssertEqual(out.recovery, .bearerTokenRefulfill)
        // SAML false (non-SAML account); OverDrive false (not an OverDrive
        // title); coldLoad false (hasEverStartedPlayback defaults true).
        // Disjunction: false — see the mid-listen pin below for why that is a
        // preserved shipped defect rather than a choice.
        XCTAssertFalse(out.keepsPlayerLoading,
            "No term of the shipped disjunction holds for a mid-listen bearer-token expiry, so it publishes .error")
    }

    func testDecide_coldLoadWithContentOnDisk_selectsColdLoadReopen() throws {
        let out = try XCTUnwrap(published(
            context(error: plainError(), book: plainBook(),
                    coldLoadAttempted: false, hasEverStartedPlayback: false,
                    contentIsLocal: true)))
        XCTAssertEqual(out.recovery, .coldLoadReopen)
        // coldLoad term: !false && book != nil && !false = true.
        XCTAssertTrue(out.keepsPlayerLoading)
    }

    func testDecide_coldLoadWithContentStillDownloading_selectsAwaitThenReopen() throws {
        let out = try XCTUnwrap(published(
            context(error: plainError(), book: plainBook(),
                    coldLoadAttempted: false, hasEverStartedPlayback: false,
                    contentIsLocal: false)))
        XCTAssertEqual(out.recovery, .coldLoadAwaitContentThenReopen,
            "Re-opening the same not-yet-materialized package fails identically; the wait is the recovery (PP-4542 A)")
        XCTAssertTrue(out.keepsPlayerLoading,
            "The cold-load term holds, and the wait is exactly the case the loading shell exists for")
    }

    // MARK: - (b) Precedence between simultaneously-satisfied arms

    func testPrecedence_suppressionBeatsEveryOtherArm() {
        makeAccountSAMLWithCredentials()
        let outcome = AudiobookPlaybackRecoveryReducer.decide(
            context(error: authRequiredError(extraUserInfo: ["httpStatusCode": 410]),
                    book: bearerTokenBook(),
                    isAwaitingContentDownload: true,
                    overdriveAttempted: false, bearerAttempted: false,
                    coldLoadAttempted: false, hasEverStartedPlayback: false,
                    contentIsLocal: false))
        XCTAssertEqual(outcome, .suppressFollowOnFailure,
            "Suppression is first in the chain: while a content wait is in flight NO recovery may start, or the wait races its own re-open")
    }

    func testPrecedence_samlBeatsBearerTokenRefulfill() throws {
        makeAccountSAMLWithCredentials()
        // One error that is BOTH the OpenAccessPlayer auth-required signal and a
        // 410 expired-entitlement signal, on a bearer-token title.
        let out = try XCTUnwrap(published(
            context(error: authRequiredError(extraUserInfo: ["httpStatusCode": 410]),
                    book: bearerTokenBook(), bearerAttempted: false)))
        XCTAssertEqual(out.recovery, .samlReauth,
            "Stale credentials must be refreshed first — a re-fulfill made with the same expired session just re-fails")
        // SAML term true.
        XCTAssertTrue(out.keepsPlayerLoading)
    }

    func testPrecedence_samlBeatsColdLoadReopen() throws {
        makeAccountSAMLWithCredentials()
        let out = try XCTUnwrap(published(
            context(error: authRequiredError(), book: plainBook(),
                    coldLoadAttempted: false, hasEverStartedPlayback: false)))
        XCTAssertEqual(out.recovery, .samlReauth,
            "A silent re-open on stale SAML credentials hits the same 401 and burns the single cold-load attempt")
        // SAML term true; the coldLoad term is also true here. Either alone
        // carries the disjunction.
        XCTAssertTrue(out.keepsPlayerLoading)
    }

    func testPrecedence_bearerTokenBeatsColdLoadReopen() throws {
        let out = try XCTUnwrap(published(
            context(error: httpError(410), book: bearerTokenBook(),
                    bearerAttempted: false,
                    coldLoadAttempted: false, hasEverStartedPlayback: false)))
        XCTAssertEqual(out.recovery, .bearerTokenRefulfill,
            "A first-play entitlement expiry needs a fresh manifest, not a re-open of the stale one")
        // SAML false; OverDrive false; coldLoad TRUE (!hasEverStartedPlayback,
        // a book, not yet attempted). Disjunction: true — and the recovery that
        // runs is the bearer-token one, which does NOT itself supply a term.
        // The published state comes from the context, not from the arm.
        XCTAssertTrue(out.keepsPlayerLoading,
            "The cold-load term holds even though the cold-load ARM lost, and the shipped disjunction reads the context, not the winner")
    }

    /// The bound is per-arm, not shared: an exhausted bearer-token attempt must
    /// fall THROUGH to the cold-load arm rather than short-circuit the chain.
    func testPrecedence_bearerExhausted_fallsThroughToColdLoadReopen() throws {
        let out = try XCTUnwrap(published(
            context(error: httpError(410), book: bearerTokenBook(),
                    bearerAttempted: true,
                    coldLoadAttempted: false, hasEverStartedPlayback: false)))
        XCTAssertEqual(out.recovery, .coldLoadReopen)
        XCTAssertTrue(out.keepsPlayerLoading)
    }

#if FEATURE_OVERDRIVE
    // `OverdriveDistributorKey` is an ObjC constant vended by OverdriveProcessor,
    // which only links under FEATURE_OVERDRIVE — hence the import at file scope
    // and this fixture living inside the conditional.
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

    func testDecide_overdriveSignedURLExpiry_selectsOverdriveRefulfill() throws {
        let out = try XCTUnwrap(published(
            context(error: httpError(410), book: overdriveBook(), overdriveAttempted: false)))
        XCTAssertEqual(out.recovery, .overdriveRefulfill)
        // OverDrive term true; coldLoad false (hasEverStartedPlayback defaults true).
        XCTAssertTrue(out.keepsPlayerLoading)
    }

    func testPrecedence_samlBeatsOverdriveRefulfill() throws {
        makeAccountSAMLWithCredentials()
        let out = try XCTUnwrap(published(
            context(error: authRequiredError(extraUserInfo: ["httpStatusCode": 410]),
                    book: overdriveBook(), overdriveAttempted: false)))
        XCTAssertEqual(out.recovery, .samlReauth)
        XCTAssertTrue(out.keepsPlayerLoading)
    }

    /// Synthetic overlap: no circulation manager emits an OverDrive-distributor
    /// title with a bearer-token acquisition. Included because the reducer
    /// accepts the input and the ordering must be defined — the OverDrive arm
    /// routes through the download centre's 302 header dance, which the generic
    /// bearer-token re-fulfill does not perform.
    func testPrecedence_overdriveBeatsBearerTokenRefulfill() throws {
        let out = try XCTUnwrap(published(
            context(error: httpError(410),
                    book: overdriveBook(bearerTokenAcquisition: true),
                    overdriveAttempted: false, bearerAttempted: false)))
        XCTAssertEqual(out.recovery, .overdriveRefulfill)
        XCTAssertTrue(out.keepsPlayerLoading)
    }

    func testPrecedence_overdriveBeatsColdLoadReopen() throws {
        let out = try XCTUnwrap(published(
            context(error: httpError(410), book: overdriveBook(),
                    overdriveAttempted: false,
                    coldLoadAttempted: false, hasEverStartedPlayback: false)))
        XCTAssertEqual(out.recovery, .overdriveRefulfill,
            "A first-play signed-URL expiry needs fresh URLs; re-opening the same expired manifest fails identically")
        XCTAssertTrue(out.keepsPlayerLoading)
    }

    /// Per-arm bound, same property as the bearer-token fall-through.
    func testPrecedence_overdriveExhausted_fallsThroughToColdLoadReopen() throws {
        let out = try XCTUnwrap(published(
            context(error: httpError(410), book: overdriveBook(),
                    overdriveAttempted: true,
                    coldLoadAttempted: false, hasEverStartedPlayback: false)))
        XCTAssertEqual(out.recovery, .coldLoadReopen)
        // OverDrive term now false (attempt spent); coldLoad term carries it.
        XCTAssertTrue(out.keepsPlayerLoading)
    }
#endif

    // MARK: - (c) Terminal shapes

    func testDecide_noArmApplies_midPlayback_isTerminalWithoutAlert() throws {
        let out = try XCTUnwrap(published(
            context(error: plainError(), book: plainBook(), hasEverStartedPlayback: true)))
        XCTAssertEqual(out.recovery, .terminal(dismissAndAlert: false),
            "A failure after playback started publishes the error but must NOT dismiss the player — the patron is mid-listen")
        // No term holds. `.terminal` implies this as a theorem: it is selected
        // only when every arm declined, and each of the three disjunction terms
        // is one of those arms' predicates.
        XCTAssertFalse(out.keepsPlayerLoading)
    }

    func testDecide_coldLoadAlreadyAttempted_isTerminalWithAlert() throws {
        let out = try XCTUnwrap(published(
            context(error: plainError(), book: plainBook(),
                    coldLoadAttempted: true, hasEverStartedPlayback: false)))
        XCTAssertEqual(out.recovery, .terminal(dismissAndAlert: true),
            "A cold load that persisted past its one silent re-open dismisses the player and surfaces the unavailable alert")
        XCTAssertFalse(out.keepsPlayerLoading)
    }

    func testDecide_noBook_isTerminalWithoutAlert() throws {
        let out = try XCTUnwrap(published(
            context(error: plainError(), book: nil, hasEverStartedPlayback: false)))
        XCTAssertEqual(out.recovery, .terminal(dismissAndAlert: false),
            "With no current book there is nothing to dismiss or re-open")
        // coldLoad needs `hasCurrentBook`, so a nil book zeroes that term too.
        XCTAssertFalse(out.keepsPlayerLoading)
    }

    // MARK: - (d) The published state is a function of the CONTEXT, not the case

    /// THE DISCRIMINATING PAIR, and the test this suite previously lacked.
    ///
    /// One recovery — `.bearerTokenRefulfill` — with two published states,
    /// differing only in `hasEverStartedPlayback`. It is the only recovery for
    /// which this is possible, because it is selected on a predicate that is not
    /// a term of the shipped `willRecover` disjunction; the other four imply
    /// their published state as a theorem.
    ///
    /// A reducer that computed the published state from the recovery CASE cannot
    /// satisfy both halves at once, so both are asserted together.
    func testPublishedState_sameBearerTokenRecovery_differsByColdLoadTerm() throws {
        let midListen = try XCTUnwrap(published(
            context(error: httpError(410), book: bearerTokenBook(),
                    bearerAttempted: false,
                    coldLoadAttempted: true, hasEverStartedPlayback: true)))
        let firstPlay = try XCTUnwrap(published(
            context(error: httpError(410), book: bearerTokenBook(),
                    bearerAttempted: false,
                    coldLoadAttempted: false, hasEverStartedPlayback: false)))

        XCTAssertEqual(midListen.recovery, .bearerTokenRefulfill)
        XCTAssertEqual(firstPlay.recovery, .bearerTokenRefulfill,
            "arrange: both cells must select the SAME recovery, or the pair does not discriminate")
        XCTAssertNotEqual(midListen.keepsPlayerLoading, firstPlay.keepsPlayerLoading,
            "One recovery, two published states: the state is read off the context's cold-load term, which the recovery case cannot carry")
        XCTAssertFalse(midListen.keepsPlayerLoading)
        XCTAssertTrue(firstPlay.keepsPlayerLoading)
    }

    /// PINS A KNOWN DEFECT IN THE SHIPPED BEHAVIOUR, NOT A DESIRED OUTCOME.
    ///
    /// 323-Cause-3 added the `.bearerTokenRefulfill` arm and did not add a term
    /// to the `willRecover` disjunction. So a BiblioBoard / Unlimited Listens
    /// title whose entitlement expires MID-LISTEN — where no other term holds —
    /// publishes `.error` and then immediately re-opens. That is not only the
    /// error-then-recover flicker (PP-4800): `AudiobookSessionPresenter` calls
    /// `clearActiveSession()` on any `.error`, so the player UI is torn down and
    /// rebuilt under the patron.
    ///
    /// Asserted as-is so the decomposition reproduces the shipped behaviour
    /// rather than changing it. Adding
    /// `|| shouldTriggerBearerTokenRefulfillForPlaybackFailure(…)` to
    /// `recoveryIsExpected` is the fix, and it fails exactly this assertion.
    ///
    /// (Formerly `testKeepsPlayerLoading_bearerTokenRefulfill_isFalse`; renamed
    /// when the published state stopped being a property of the enum case. The
    /// context and the asserted value are unchanged.)
    func testPublishedState_bearerTokenMidListen_publishesError() throws {
        let out = try XCTUnwrap(published(
            context(error: httpError(403), book: bearerTokenBook(),
                    bearerAttempted: false,
                    coldLoadAttempted: true, hasEverStartedPlayback: true)))
        XCTAssertEqual(out.recovery, .bearerTokenRefulfill)
        XCTAssertFalse(out.keepsPlayerLoading,
            "Reproduces the shipped disjunction, which has no bearer-token term — the recovery runs but the session has already published .error")
    }
}
