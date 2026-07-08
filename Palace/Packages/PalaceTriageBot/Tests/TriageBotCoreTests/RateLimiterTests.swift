import XCTest
@testable import TriageBotCore

final class RateLimiterTests: XCTestCase {

    func testRecord_belowMinuteLimit_returnsTrue() {
        let limiter = FallbackRateLimiter(limits: .init(maxCallsPerMinute: 3, maxCallsPerSession: 100))
        XCTAssertTrue(limiter.record())
        XCTAssertTrue(limiter.record())
        XCTAssertTrue(limiter.record())
    }

    func testRecord_exceedingMinuteLimit_returnsFalse() {
        let limiter = FallbackRateLimiter(limits: .init(maxCallsPerMinute: 2, maxCallsPerSession: 100))
        XCTAssertTrue(limiter.record())
        XCTAssertTrue(limiter.record())
        XCTAssertFalse(limiter.record(), "Third call within the same minute must be rejected")
        XCTAssertFalse(limiter.record(), "Continued rejection — sliding window hasn't slid")
    }

    func testRecord_slidingWindowOpens_afterTimeAdvances() {
        var fakeNow = Date(timeIntervalSince1970: 0)
        let limiter = FallbackRateLimiter(
            limits: .init(maxCallsPerMinute: 2, maxCallsPerSession: 100),
            now: { fakeNow }
        )
        XCTAssertTrue(limiter.record())
        XCTAssertTrue(limiter.record())
        XCTAssertFalse(limiter.record())

        // Advance past the 60s window — sliding window slides.
        fakeNow = fakeNow.addingTimeInterval(61)
        XCTAssertTrue(limiter.record(), "After 60s+, the old calls roll off and a slot reopens")
    }

    func testRecord_sessionLimit_independentOfMinuteWindow() {
        var fakeNow = Date(timeIntervalSince1970: 0)
        let limiter = FallbackRateLimiter(
            limits: .init(maxCallsPerMinute: 100, maxCallsPerSession: 3),
            now: { fakeNow }
        )
        XCTAssertTrue(limiter.record())
        XCTAssertTrue(limiter.record())
        XCTAssertTrue(limiter.record())
        XCTAssertFalse(limiter.record(), "Session cap hit")

        // Even after the window slides, session cap holds — those calls
        // count against the session forever.
        fakeNow = fakeNow.addingTimeInterval(3600)
        XCTAssertFalse(limiter.record(), "Session cap survives window slide")
    }

    func testResetSession_freshSessionGetsFreshBudget() {
        var fakeNow = Date(timeIntervalSince1970: 0)
        let limiter = FallbackRateLimiter(
            limits: .init(maxCallsPerMinute: 100, maxCallsPerSession: 2),
            now: { fakeNow }
        )
        XCTAssertTrue(limiter.record())
        XCTAssertTrue(limiter.record())
        XCTAssertFalse(limiter.record())

        limiter.resetSession()
        XCTAssertTrue(limiter.record(), "After resetSession the per-session budget renews")
        XCTAssertTrue(limiter.record())
        XCTAssertFalse(limiter.record(), "But the cap still applies to the new session")

        // Sliding window state is preserved across resetSession — it was
        // tracking burst within a window, not per-session.
        fakeNow = fakeNow.addingTimeInterval(61)
        limiter.resetSession()
        XCTAssertTrue(limiter.record())
    }
}
