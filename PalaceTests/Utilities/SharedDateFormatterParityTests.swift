//
//  SharedDateFormatterParityTests.swift
//  PalaceTests
//
//  Pins the date strings and parsed dates produced through shared formatters
//  (PP-5498) to the output of the per-call formatters they replaced.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class SharedDateFormatterParityTests: XCTestCase {

    // MARK: - Fixtures

    /// Whole, fractional, negative, leap-day and far-future instants.
    private let instants: [TimeInterval] = [
        0,
        -1,
        -2_208_988_800.5,
        951_782_400,
        1_700_000_000,
        1_700_000_000.123456,
        1_700_000_000.999999,
        1_700_000_059.9995,
        253_402_300_799
    ]

    /// A default zone with a half-hour offset, one with a 45-minute offset,
    /// and one with daylight saving, so a formatter that froze or ignored the
    /// default zone shows up as a mismatch.
    private let defaultZones = ["UTC", "America/New_York", "Asia/Kathmandu", "Pacific/Chatham"]

    private func withDefaultTimeZone(_ identifier: String, _ body: () throws -> Void) rethrows {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: identifier)!
        defer { NSTimeZone.default = saved }
        try body()
    }

    // MARK: - Reference implementations (the per-call formatters before PP-5498)

    private func legacyRFC3339String(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func legacyISO8601DateOnly(_ string: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withFullDate]
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = isoFormatter.date(from: string) {
            return date
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy"
        return dateFormatter.date(from: string)
    }

    private func legacyBookmarkTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func legacyOPDS2Date(_ dateString: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: dateString) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: dateString) { return date }
        let rfc3339Formatter = DateFormatter()
        rfc3339Formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        rfc3339Formatter.locale = Locale(identifier: "en_US_POSIX")
        rfc3339Formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return rfc3339Formatter.date(from: dateString)
    }

    private func legacyTrackerMinute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - rfc3339String (registry save path)

    /// The registry writes availability dates with this string; a byte change
    /// would rewrite every saved record on the next save.
    func testRFC3339String_MatchesPerCallFormatter_AcrossZonesAndFractions() {
        for zone in defaultZones {
            withDefaultTimeZone(zone) {
                for t in instants {
                    let date = Date(timeIntervalSince1970: t)
                    XCTAssertEqual((date as NSDate).rfc3339String(), legacyRFC3339String(date),
                                   "rfc3339String drifted for t=\(t) with default zone \(zone)")
                }
            }
        }
    }

    /// Fractional seconds are dropped, not rounded to the nearest second.
    func testRFC3339String_DropsFractionalSeconds() {
        let date = NSDate(timeIntervalSince1970: 1_700_000_000.75)
        XCTAssertEqual(date.rfc3339String(), "2023-11-14T22:13:20Z")
    }

    func testRFC3339String_RepeatedCalls_ReturnTheSameBytes() {
        let date = NSDate(timeIntervalSince1970: 951_782_400)
        let first = date.rfc3339String()
        for _ in 0..<100 {
            XCTAssertEqual(date.rfc3339String(), first)
        }
        XCTAssertEqual(first, "2000-02-29T00:00:00Z")
    }

    // MARK: - date(withISO8601DateString:)

    func testISO8601DateString_MatchesPerCallFormatter_FullDateAndYearFallback() {
        let inputs = ["2020-06-02", "2000-02-29", "2020", "1999", "not a date", "", "2020-13-40"]
        for zone in defaultZones {
            withDefaultTimeZone(zone) {
                for input in inputs {
                    XCTAssertEqual(NSDate.date(withISO8601DateString: input) as Date?,
                                   legacyISO8601DateOnly(input),
                                   "date(withISO8601DateString:) drifted for '\(input)' with default zone \(zone)")
                }
            }
        }
    }

    /// The year-only fallback resolves in the default time zone; a shared
    /// formatter must keep following that zone when it changes.
    func testISO8601YearFallback_FollowsDefaultZoneChange_AfterFirstUse() {
        withDefaultTimeZone("UTC") {
            XCTAssertEqual((NSDate.date(withISO8601DateString: "2020") as Date?)?.timeIntervalSince1970,
                           1_577_836_800)
        }
        withDefaultTimeZone("Asia/Kathmandu") {
            XCTAssertEqual((NSDate.date(withISO8601DateString: "2020") as Date?)?.timeIntervalSince1970,
                           1_577_816_100)
        }
    }

    // MARK: - Date.iso8601 (audiobook bookmark timestamps)

    func testBookmarkTimestamp_MatchesPerCallFormatter_AcrossZonesAndFractions() {
        for zone in defaultZones {
            withDefaultTimeZone(zone) {
                for t in instants {
                    let date = Date(timeIntervalSince1970: t)
                    XCTAssertEqual(date.iso8601, legacyBookmarkTimestamp(date),
                                   "iso8601 drifted for t=\(t) with default zone \(zone)")
                }
            }
        }
        XCTAssertEqual(Date(timeIntervalSince1970: 1_700_000_000.75).iso8601, "2023-11-14T22:13:20Z")
    }

    // MARK: - OPDS2Feed.makeDecoder

    private struct Stamped: Decodable { let d: Date }

    private func decodeWithFeedDecoder(_ string: String) -> Date? {
        let json = Data("{\"d\":\"\(string)\"}".utf8)
        return try? OPDS2Feed.makeDecoder().decode(Stamped.self, from: json).d
    }

    func testOPDS2Decoder_MatchesPerCallFormatters_ForEveryAcceptedShape() {
        let inputs = [
            "2023-11-14T22:13:20.123Z",
            "2023-11-14T22:13:20.123456Z",
            "2023-11-14T22:13:20Z",
            "2023-11-14T22:13:20+02:00",
            "2023-11-14T22:13:20.5-05:30",
            "2023-11-14T22:13:20+0200",
            "2023-11-14T22:13:20-0800",
            "2023-11-14",
            "garbage"
        ]
        for zone in defaultZones {
            withDefaultTimeZone(zone) {
                for input in inputs {
                    XCTAssertEqual(decodeWithFeedDecoder(input), legacyOPDS2Date(input),
                                   "OPDS2 date decoding drifted for '\(input)' with default zone \(zone)")
                }
            }
        }
    }

    /// A non-fractional date decoded first must not stop a later fractional
    /// date from decoding (the shared-formatter ordering defect the per-call
    /// formatters were introduced to avoid).
    func testOPDS2Decoder_FractionalAfterPlain_StillDecodes() {
        XCTAssertNotNil(decodeWithFeedDecoder("2023-11-14T22:13:20Z"))
        XCTAssertEqual(decodeWithFeedDecoder("2023-11-14T22:13:20.250Z")?.timeIntervalSince1970,
                       1_700_000_000.25)
    }

    func testOPDS2Decoder_ConcurrentDecodes_AgreeWithSerialResult() {
        let inputs = ["2023-11-14T22:13:20.123Z", "2023-11-14T22:13:20Z", "2023-11-14T22:13:20+0200"]
        let expected = inputs.map(legacyOPDS2Date)
        let mismatches = ManagedAtomicCounter()
        DispatchQueue.concurrentPerform(iterations: 300) { i in
            let input = inputs[i % inputs.count]
            if decodeWithFeedDecoder(input) != expected[i % inputs.count] {
                mismatches.increment()
            }
        }
        XCTAssertEqual(mismatches.value, 0)
    }

    // MARK: - AudiobookTimeTracker minute key

    /// The tracker files time under the UTC minute an instant falls in, so the
    /// index is the floor of the instant in minutes, also below zero.
    func testTrackerMinuteIndex_IsTheFloorOfTheUTCMinute() {
        let cases: [(TimeInterval, Int64)] = [
            (-60.0001, -2), (-60, -1), (-59.9999, -1), (-0.0001, -1),
            (0, 0), (0.0001, 0), (59.9999, 0), (60, 1),
            (1_700_000_039.999, 28_333_333), (1_700_000_040, 28_333_334),
            (1_700_000_099.9995, 28_333_334), (1_700_000_100, 28_333_335)
        ]
        for (t, expected) in cases {
            XCTAssertEqual(AudiobookTimeTracker.minuteIndex(of: Date(timeIntervalSince1970: t)), expected,
                           "minute index for t=\(t)")
        }
    }

    /// The key string is the per-call formatter's output for the minute's
    /// first instant, whatever the default time zone.
    func testTrackerMinuteString_MatchesPerCallFormatterAtTheMinuteStart() {
        let indices: [Int64] = [-37_016_484, -1, 0, 15_863_040, 28_333_333, 28_333_334, 4_223_371_679]
        for zone in defaultZones {
            withDefaultTimeZone(zone) {
                for index in indices {
                    let start = Date(timeIntervalSince1970: TimeInterval(index) * 60)
                    XCTAssertEqual(AudiobookTimeTracker.minuteString(forMinuteIndex: index), legacyTrackerMinute(start),
                                   "minute string drifted for index \(index) with default zone \(zone)")
                }
            }
        }
        XCTAssertEqual(AudiobookTimeTracker.minuteString(forMinuteIndex: 28_333_334), "2023-11-14T22:14Z")
    }
}

private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
