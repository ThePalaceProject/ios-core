//
//  LoanEvictionPolicyTests.swift
//  PalaceTests
//
//  Reliability WS-C — exhaustive matrix for the INV-2 guardrail.
//  {expired / not / no-expiry} × {online / offline} × {within / after grace}.
//  The single most important assertion: expired + offline => .keep
//  (never delete a downloaded file offline on a cached `until`).
//

import XCTest
@testable import Palace

@MainActor
final class LoanEvictionPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let grace: TimeInterval = 100

    // MARK: - No expiry

    func testNoExpiration_online_keeps() {
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: nil, now: now, isOnline: true, grace: grace),
            .keep)
    }

    func testNoExpiration_offline_keeps() {
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: nil, now: now, isOnline: false, grace: grace),
            .keep)
    }

    // MARK: - Not yet expired

    func testNotExpired_online_keeps() {
        let until = now.addingTimeInterval(1000)
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: until, now: now, isOnline: true, grace: grace),
            .keep)
    }

    func testNotExpired_offline_keeps() {
        let until = now.addingTimeInterval(1000)
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: until, now: now, isOnline: false, grace: grace),
            .keep)
    }

    // MARK: - Expired + OFFLINE (INV-2 — the key guard)

    func testOfflineExpiredByCachedUntil_keepsFile() {
        let until = now.addingTimeInterval(-1000) // long past
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: until, now: now, isOnline: false, grace: grace),
            .keep,
            "INV-2: an offline device must NEVER evict on a cached `until` alone")
    }

    func testOfflineExpiredWithinGrace_keepsFile() {
        let until = now.addingTimeInterval(-10) // just expired
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: until, now: now, isOnline: false, grace: grace),
            .keep)
    }

    func testOfflineExpiredPastGrace_stillKeeps() {
        // Even well past the grace window, OFFLINE never evicts.
        let until = now.addingTimeInterval(-10_000)
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: until, now: now, isOnline: false, grace: grace),
            .keep)
    }

    // MARK: - Expired + ONLINE

    func testOnlineExpiredWithinGrace_confirmsWithServer() {
        let until = now.addingTimeInterval(-10) // within 100s grace
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: until, now: now, isOnline: true, grace: grace),
            .confirmWithServer)
    }

    func testOnlineExpiredPastGrace_evicts() {
        let until = now.addingTimeInterval(-1000) // past 100s grace
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: until, now: now, isOnline: true, grace: grace),
            .evict)
    }

    // MARK: - Boundaries

    func testOnlineExactlyAtGraceEdge_evicts() {
        // now == until + grace  -> `now >= until+grace` is true -> evict
        let until = now.addingTimeInterval(-grace)
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: until, now: now, isOnline: true, grace: grace),
            .evict)
    }

    func testOnlineJustInsideGraceEdge_confirmsWithServer() {
        // now < until + grace by 1s -> confirmWithServer
        let until = now.addingTimeInterval(-grace + 1)
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: until, now: now, isOnline: true, grace: grace),
            .confirmWithServer)
    }

    func testOnlineExactlyAtExpiration_withZeroGrace_evicts() {
        // now == until, grace 0 -> now >= until -> evict
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: now, now: now, isOnline: true, grace: 0),
            .evict)
    }

    func testExactlyAtExpiration_notPastYet_keeps() {
        // now == until with a positive grace -> within grace -> confirmWithServer,
        // and offline -> keep. Pin both to lock the boundary semantics.
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: now, now: now, isOnline: true, grace: grace),
            .confirmWithServer)
        XCTAssertEqual(
            LoanEvictionPolicy.decide(expiration: now, now: now, isOnline: false, grace: grace),
            .keep)
    }
}
