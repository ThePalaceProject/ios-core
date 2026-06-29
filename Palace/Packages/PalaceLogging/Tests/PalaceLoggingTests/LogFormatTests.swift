import XCTest
@testable import PalaceLogging

/// Format coverage for `Log.formattedTimestamp(_:)` — the internal helper that
/// replaced the public `Log.dateFormatter` (removed in the Swift 6 conversion
/// because a shared mutable `DateFormatter` is non-`Sendable` global state).
/// Lives here, in PalaceLogging's own test target, because the helper is
/// `internal` (reachable via `@testable`); the prior app-target test referenced
/// the now-removed public API.
final class LogFormatTests: XCTestCase {

    func testFormattedTimestamp_producesExpectedFormat() {
        let formatted = Log.formattedTimestamp(Date())

        XCTAssertFalse(formatted.isEmpty, "timestamp should be non-empty")
        XCTAssertEqual(formatted.count, 19,
                       "'yyyy-MM-dd HH:mm:ss' is 19 characters")
        XCTAssertTrue(formatted.contains("-"), "must contain '-' date separators")
        XCTAssertTrue(formatted.contains(":"), "must contain ':' time separators")
    }

    func testFormattedTimestamp_isStableForAFixedDate() {
        // Fixed epoch in UTC-agnostic terms: assert the structural shape (digits +
        // separators in the right positions), not an absolute value (timezone).
        let s = Log.formattedTimestamp(Date(timeIntervalSince1970: 0))
        XCTAssertEqual(s.count, 19)
        // yyyy-MM-dd HH:mm:ss → positions of separators are fixed.
        let chars = Array(s)
        XCTAssertEqual(chars[4], "-")
        XCTAssertEqual(chars[7], "-")
        XCTAssertEqual(chars[10], " ")
        XCTAssertEqual(chars[13], ":")
        XCTAssertEqual(chars[16], ":")
    }
}
