//
//  AdobeLicensorRefreshTests.swift
//  PalaceTests
//
//  PP-3649 root cause. The CM's short client token lives 60 minutes
//  (`expires = {"minutes": 60}`) and the CM enforces expiry on decode. iOS
//  stored that token once at sign-in and never refreshed it, while PP-3649
//  moved Adobe activation to first-borrow — arbitrarily later. Adobe rejects
//  the stale token as "Incorrect barcode or PIN", which reads as a patron
//  credential problem and is not one.
//
//  Android has never had this: `BorrowACSM.adobeDeviceActivate` re-runs the
//  patron profile request and activates with the token it just received.
//
//  These pin the choice of WHICH licensor activation uses.
//

import XCTest
@testable import Palace

final class AdobeLicensorRefreshTests: XCTestCase {

    private let stored: [String: Any] = ["vendor": "ThePalaceProject", "clientToken": "STORED|123|patron|sig"]
    private let fresh: [String: Any] = ["vendor": "ThePalaceProject", "clientToken": "FRESH|999|patron|sig"]

    // MARK: - The fix

    func test_resolve_prefersTheFreshlyMintedLicensor() async {
        let result = await AdobeLicensorRefresh.resolve(stored: stored, fetch: { self.fresh })

        XCTAssertEqual(result.licensor?["clientToken"] as? String, "FRESH|999|patron|sig",
                       "activation must use the token just minted, not the one stored at sign-in — that is the whole defect")
        XCTAssertTrue(result.wasRefreshed)
    }

    /// The caller persists only on a real refresh; writing back a value that
    /// came from the keychain would be a pointless keychain write.
    func test_resolve_whenFetchFails_doesNotClaimARefresh() async {
        let result = await AdobeLicensorRefresh.resolve(stored: stored, fetch: { nil })

        XCTAssertFalse(result.wasRefreshed)
        XCTAssertEqual(result.licensor?["clientToken"] as? String, "STORED|123|patron|sig")
    }

    // MARK: - Fallback must not make things worse

    func test_resolve_whenFetchFails_fallsBackToStored() async {
        let result = await AdobeLicensorRefresh.resolve(stored: stored, fetch: { nil })

        XCTAssertNotNil(result.licensor,
                        "an unreachable refresh must not fail a borrow that the stored token could still satisfy")
    }

    func test_resolve_whenFetchReturnsUnusableLicensor_keepsStored() async {
        let empty: [String: Any] = ["vendor": "", "clientToken": ""]
        let result = await AdobeLicensorRefresh.resolve(stored: stored, fetch: { empty })

        XCTAssertEqual(result.licensor?["clientToken"] as? String, "STORED|123|patron|sig",
                       "a refreshed-but-empty document must not displace a usable stored licensor")
        XCTAssertFalse(result.wasRefreshed)
    }

    func test_resolve_noStoredAndNoFresh_returnsNil() async {
        let result = await AdobeLicensorRefresh.resolve(stored: nil, fetch: { nil })

        XCTAssertNil(result.licensor)
        XCTAssertFalse(result.wasRefreshed)
    }

    /// First sign-in: nothing stored yet, refresh supplies everything.
    func test_resolve_noStoredButFreshAvailable_usesFresh() async {
        let result = await AdobeLicensorRefresh.resolve(stored: nil, fetch: { self.fresh })

        XCTAssertEqual(result.licensor?["clientToken"] as? String, "FRESH|999|patron|sig")
        XCTAssertTrue(result.wasRefreshed)
    }

    // MARK: - Usability predicate

    func test_isUsable_requiresBothVendorAndClientToken() {
        XCTAssertTrue(AdobeLicensorRefresh.isUsable(fresh))
        XCTAssertFalse(AdobeLicensorRefresh.isUsable(nil))
        XCTAssertFalse(AdobeLicensorRefresh.isUsable([:]))
        XCTAssertFalse(AdobeLicensorRefresh.isUsable(["vendor": "V"]))
        XCTAssertFalse(AdobeLicensorRefresh.isUsable(["clientToken": "T"]))
        XCTAssertFalse(AdobeLicensorRefresh.isUsable(["vendor": "", "clientToken": "T"]))
        XCTAssertFalse(AdobeLicensorRefresh.isUsable(["vendor": "V", "clientToken": ""]))
    }

    /// The fetch must actually be consulted — a `resolve` that returned
    /// `stored` without calling it would pass every assertion above.
    func test_resolve_alwaysConsultsTheFetch() async {
        let called = Counter()
        _ = await AdobeLicensorRefresh.resolve(stored: stored, fetch: {
            called.bump()
            return nil
        })
        XCTAssertEqual(called.value, 1, "the refresh must be attempted on every activation, not skipped when something is stored")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _v = 0
        func bump() { lock.withLock { _v += 1 } }
        var value: Int { lock.withLock { _v } }
    }
    // MARK: - Expiry: the invariant that was previously unrepresentable

    /// The CM writes SHORTNAME|expires|patron|signature with a 60-minute TTL.
    /// Before this predicate existed, staleness was not a state the codebase
    /// could name — which is why no test could fail and PP-3649 shipped.
    func test_clientTokenExpiry_readsTheNumericDateFromTheToken() {
        // 2026-09-09T20:00:00Z
        let expiry = Date(timeIntervalSince1970: 1788998400)
        let token = "A1QA|1788998400|patron123|c2lnbmF0dXJl"

        XCTAssertEqual(AdobeLicensorRefresh.clientTokenExpiry(token), expiry)
    }

    func test_isExpired_pastToken_isExpired() {
        let past = Date().addingTimeInterval(-3600)
        let licensor: [String: Any] = ["vendor": "V", "clientToken": "A1QA|\(Int(past.timeIntervalSince1970))|p|sig"]

        XCTAssertTrue(AdobeLicensorRefresh.isExpired(licensor),
                      "a token minted more than its TTL ago must read as expired — this is PP-3649's exact condition")
    }

    func test_isExpired_futureToken_isNotExpired() {
        let future = Date().addingTimeInterval(1800)
        let licensor: [String: Any] = ["vendor": "V", "clientToken": "A1QA|\(Int(future.timeIntervalSince1970))|p|sig"]

        XCTAssertFalse(AdobeLicensorRefresh.isExpired(licensor))
    }

    /// An unparseable token is splitClientToken's failure, not staleness.
    /// Reporting it as expired would mask the real defect behind a refresh.
    func test_isExpired_unparseableToken_isNotReportedAsStale() {
        XCTAssertFalse(AdobeLicensorRefresh.isExpired(["vendor": "V", "clientToken": "noSeparator"]))
        XCTAssertFalse(AdobeLicensorRefresh.isExpired(["vendor": "V", "clientToken": "A1QA|notANumber|p|sig"]))
        XCTAssertFalse(AdobeLicensorRefresh.isExpired(nil))
    }

    /// Boundary: exactly at the expiry instant the token is not yet past it.
    func test_isExpired_atTheExactExpiryInstant_isNotYetExpired() {
        let now = Date(timeIntervalSince1970: 1788998400)
        let licensor: [String: Any] = ["vendor": "V", "clientToken": "A1QA|1788998400|p|sig"]

        XCTAssertFalse(AdobeLicensorRefresh.isExpired(licensor, now: now))
        XCTAssertTrue(AdobeLicensorRefresh.isExpired(licensor, now: now.addingTimeInterval(1)))
    }
}
