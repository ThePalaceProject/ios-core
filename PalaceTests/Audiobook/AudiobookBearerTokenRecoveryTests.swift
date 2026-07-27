//
//  AudiobookBearerTokenRecoveryTests.swift
//  PalaceTests
//
//  323-Cause-3 (HelpSpot #18471): pins the GENERALIZED mid-listen
//  expired-entitlement recovery that extends OverDrive's re-fulfill pattern to
//  bearer-token audiobooks (BiblioBoard / Unlimited Listens / other
//  `application/vnd.librarysimplified.bearer-token+json` vendors).
//
//  Like the OverDrive re-fulfill guard and the PP-4542 cold-load guard, the full
//  handleManagerState -> openAudiobook(forceRefulfill:true) -> makeLoader wiring
//  is auth-gated and proven by SoD review + device/sim validation. Here we pin
//  the PURE decision predicates so the recovery's:
//    - trigger classification (which HTTP / URLError signals count as an expired
//      entitlement),
//    - vendor allowlist (which vendors are covered vs left on the existing
//      terminal alert), and
//    - per-session bound
//  cannot silently drift. Every assertion below survives a conditional flip in
//  the production predicate (mutation-killing).
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AudiobookBearerTokenRecoveryTests: XCTestCase {

    // MARK: - Fixtures

    private func bearerTokenBook() -> TPPBook {
        TPPBookMocker.mockBook(distributorType: .BearerToken)
    }

    /// NSError shaped like a toolkit playback failure carrying an HTTP status.
    private func httpError(_ status: Int) -> NSError {
        NSError(domain: "test.playback", code: 1, userInfo: ["httpStatusCode": status])
    }

    /// URLError -1008 (resourceUnavailable) — an expired signed content URL.
    private func resourceUnavailableError() -> NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, userInfo: [:])
    }

    // MARK: - Signal classification: isResourceUnavailable

    func testResourceUnavailable_minus1008_returnsTrue() {
        XCTAssertTrue(AudiobookSessionManager.isResourceUnavailable(resourceUnavailableError()),
            "URLError -1008 (resourceUnavailable) is the signal an expired signed content URL surfaces")
    }

    func testResourceUnavailable_minus1008InUnderlyingChain_returnsTrue() {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, userInfo: [:])
        let wrapped = NSError(domain: "av", code: -11800, userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertTrue(AudiobookSessionManager.isResourceUnavailable(wrapped),
            "The -1008 may be one level down the NSUnderlyingError chain (AVFoundation wraps it)")
    }

    func testResourceUnavailable_otherURLErrorCode_returnsFalse() {
        let notConnected = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [:])
        XCTAssertFalse(AudiobookSessionManager.isResourceUnavailable(notConnected),
            "A different URLError code (e.g. notConnectedToInternet) is NOT an expired-URL signal")
    }

    func testResourceUnavailable_nonURLDomainWithSameCode_returnsFalse() {
        // Same numeric code but a different domain must NOT match — the domain
        // check is load-bearing (kills the `domain ==` mutation).
        let sameCodeOtherDomain = NSError(domain: "some.other.domain", code: NSURLErrorResourceUnavailable, userInfo: [:])
        XCTAssertFalse(AudiobookSessionManager.isResourceUnavailable(sameCodeOtherDomain),
            "-1008 only counts inside NSURLErrorDomain — a same-numbered code in another domain is unrelated")
    }

    func testResourceUnavailable_nilError_returnsFalse() {
        XCTAssertFalse(AudiobookSessionManager.isResourceUnavailable(nil))
    }

    // MARK: - Signal classification: isExpiredEntitlementSignal

    func testExpiredSignal_410_returnsTrue() {
        XCTAssertTrue(AudiobookSessionManager.isExpiredEntitlementSignal(httpError(410)),
            "HTTP 410 (Gone) is a clean expired-entitlement signal")
    }

    func testExpiredSignal_403_returnsTrue() {
        XCTAssertTrue(AudiobookSessionManager.isExpiredEntitlementSignal(httpError(403)),
            "HTTP 403 is the documented BiblioBoard mid-listen dead-end — covered by the non-destructive bearer-token recovery")
    }

    func testExpiredSignal_minus1008_returnsTrue() {
        XCTAssertTrue(AudiobookSessionManager.isExpiredEntitlementSignal(resourceUnavailableError()),
            "URLError -1008 (expired signed URL) is an expired-entitlement signal")
    }

    func testExpiredSignal_401_returnsFalse() {
        XCTAssertFalse(AudiobookSessionManager.isExpiredEntitlementSignal(httpError(401)),
            "401 is auth-required (handled by SAML re-auth / toolkit bearer refresh) — not a signed-URL expiry")
    }

    func testExpiredSignal_404_returnsFalse() {
        XCTAssertFalse(AudiobookSessionManager.isExpiredEntitlementSignal(httpError(404)),
            "404 is not an expiry signal — re-fulfilling would not help")
    }

    func testExpiredSignal_noStatusNoURLError_returnsFalse() {
        let bare = NSError(domain: "av", code: -11800, userInfo: [:])
        XCTAssertFalse(AudiobookSessionManager.isExpiredEntitlementSignal(bare),
            "A bare AVFoundation error with no extractable status and no -1008 → conservatively not an expiry")
    }

    // MARK: - Vendor allowlist + bound: shouldTriggerBearerTokenRefulfillForPlaybackFailure

    func testBearerTokenRefulfill_bearerToken410_returnsTrue() {
        XCTAssertTrue(AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: httpError(410), book: bearerTokenBook(), alreadyAttempted: false),
            "A bearer-token audiobook with a 410 expiry is exactly the case this fix recovers")
    }

    func testBearerTokenRefulfill_bearerToken403_returnsTrue() {
        XCTAssertTrue(AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: httpError(403), book: bearerTokenBook(), alreadyAttempted: false),
            "A bearer-token 403 (BiblioBoard 'Animal Farm' case) must recover, not dead-end")
    }

    func testBearerTokenRefulfill_bearerTokenMinus1008_returnsTrue() {
        XCTAssertTrue(AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: resourceUnavailableError(), book: bearerTokenBook(), alreadyAttempted: false),
            "A bearer-token expired signed URL (-1008) must recover via a fresh re-fulfill")
    }

    func testBearerTokenRefulfill_bearerToken401_returnsFalse() {
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: httpError(401), book: bearerTokenBook(), alreadyAttempted: false),
            "A 401 is auth, not entitlement expiry — must not enter the re-fulfill path (SAML path owns it)")
    }

    func testBearerTokenRefulfill_alreadyAttempted_returnsFalse_bounded() {
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: httpError(410), book: bearerTokenBook(), alreadyAttempted: true),
            "Bounded to one re-fulfill per book per session — a second expiry must reach the terminal alert, not loop")
    }

    func testBearerTokenRefulfill_nilBook_returnsFalse() {
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: httpError(410), book: nil, alreadyAttempted: false),
            "No current book → nothing to re-fulfill")
    }

    // MARK: - Vendors LEFT on the existing terminal alert (documented non-coverage)

    func testBearerTokenRefulfill_lcpAudiobook_returnsFalse_leftOnAlert() {
        // LCP mid-listen failure is LICENSE/loan expiry, not a signed-URL expiry;
        // the on-disk .lcpa + stale .lcpl cannot be re-fulfilled into a fresh
        // license. The terminal alert is the correct outcome.
        let lcp = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: httpError(410), book: lcp, alreadyAttempted: false),
            "LCP audiobooks are deliberately left on the existing alert — re-fulfill cannot refresh an expired license")
    }

    func testBearerTokenRefulfill_findawayAudiobook_returnsFalse_leftOnAlert() {
        // Findaway carries a distinct findaway.license acquisition (never
        // bearer-token); its AudioEngine session re-fulfill is not safely
        // verifiable for a hotfix, so it stays on the alert.
        let findaway = TPPBookMocker.mockBook(distributorType: .Findaway)
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: httpError(410), book: findaway, alreadyAttempted: false),
            "Findaway/Audible are deliberately left on the existing alert — their re-fulfill is not safely verifiable")
    }

    func testBearerTokenRefulfill_openAccessAudiobook_returnsFalse() {
        // Plain open-access audiobooks stream from static (non-signed) URLs that
        // do not expire; they are not claimed by the bearer-token allowlist.
        let openAccess = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: httpError(410), book: openAccess, alreadyAttempted: false),
            "Open-access audiobooks are not bearer-token fulfilled — outside this recovery's positive allowlist")
    }

    func testBearerTokenRefulfill_overdriveAudiobook_returnsFalse_ownPath() {
        // OverDrive carries an overdrive-profile acquisition, not bearer-token,
        // so it never matches here — its dedicated 410 path handles it and is
        // kept byte-identical.
        let overdrive = TPPBookMocker.mockBook(distributorType: .OverdriveAudiobook)
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: httpError(410), book: overdrive, alreadyAttempted: false),
            "OverDrive stays on its own dedicated re-fulfill path — the bearer-token allowlist excludes it by acquisition type")
    }
}
