//
//  OPDS2CatalogsFeedDateDecodingTests.swift
//  PalaceTests
//
//  Pins what `OPDS2CatalogsFeed.fromData` does with each `updated` date shape,
//  recorded against the two-format closure it replaced, so reordering or
//  sharing the formatters cannot change a parsed value.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class OPDS2CatalogsFeedDateDecodingTests: XCTestCase {

    private static func feedJSON(updated: String) throws -> Data {
        let catalog: [String: Any] = [
            "metadata": ["id": "lib-1", "title": "Library One", "updated": updated],
            "links": [["href": "https://example.com/lib-1", "rel": "http://opds-spec.org/catalog"]]
        ]
        let feed: [String: Any] = ["metadata": ["title": "Registry"], "catalogs": [catalog], "links": []]
        return try JSONSerialization.data(withJSONObject: feed)
    }

    /// Returns the decoded `updated` value as seconds since 1970, or nil when the decode throws.
    private static func decodedSeconds(_ updated: String) throws -> Double? {
        let data = try feedJSON(updated: updated)
        guard let feed = try? OPDS2CatalogsFeed.fromData(data) else { return nil }
        return feed.catalogs.first?.metadata.updated?.timeIntervalSince1970
    }

    /// Each row is an input and the value the previous closure (fractional
    /// format first, then plain) produced for it; nil means the decode threw.
    private static let characterization: [(input: String, seconds: Double?)] = [
        // Plain seconds, every offset spelling the closure accepts.
        ("2026-04-15T10:00:00Z", 1_776_247_200),
        ("2026-04-15T10:00:00z", 1_776_247_200),
        ("2026-04-15T10:00:00+00:00", 1_776_247_200),
        ("2026-04-15T10:00:00+0000", 1_776_247_200),
        ("2026-04-15T10:00:00+00", 1_776_247_200),
        ("2026-04-15T12:30:00+02:30", 1_776_247_200),
        ("2026-04-15T05:00:00-05:00", 1_776_247_200),
        ("2026-04-15T05:00:00-0500", 1_776_247_200),
        ("2026-04-15T10:00:00GMT", 1_776_247_200),
        ("2026-04-15T10:00:00UTC", 1_776_247_200),
        // Fractional seconds: one to six digits, milliseconds kept.
        ("2026-04-15T10:00:00.1Z", 1_776_247_200.1),
        ("2026-04-15T10:00:00.12Z", 1_776_247_200.12),
        ("2026-04-15T10:00:00.123Z", 1_776_247_200.123),
        ("2026-04-15T10:00:00.123456Z", 1_776_247_200.123),
        ("2026-04-15T10:00:00.123+0000", 1_776_247_200.123),
        ("2026-04-15T10:00:00.999+02:00", 1_776_240_000.999),
        // ICU leniency the closure accepted.
        ("2026-02-30T10:00:00Z", 1_772_445_600),
        ("2026-4-5T1:2:3Z", 1_775_350_923),
        (" 2026-04-15T10:00:00Z", 1_776_247_200),
        ("2026-04-15T10:00:00Z ", 1_776_247_200),
        ("0001-01-01T00:00:00Z", -62_135_769_600),
        ("9999-12-31T23:59:59Z", 253_402_300_799),
        // Rejected.
        ("2026-04-15T10:00:00", nil),
        ("2026-04-15T10:00:00.123", nil),
        ("2026-04-15", nil),
        ("2026-04-15 10:00:00Z", nil),
        ("2026-04-15T10:00Z", nil),
        ("2026-04-15T10:00:00.Z", nil),
        ("2026-04-15T10:00:00ZZ", nil),
        ("2026-04-15T25:00:00Z", nil),
        ("2026-04-15T10:00:60Z", nil),
        ("2026-13-45T10:00:00Z", nil),
        ("not a date", nil),
        ("", nil)
    ]

    func testFromData_UpdatedDate_ParsesEachFormatAsBefore() throws {
        for row in Self.characterization {
            let actual = try Self.decodedSeconds(row.input)
            switch (row.seconds, actual) {
            case (nil, nil):
                break
            case let (expected?, actual?):
                XCTAssertEqual(actual, expected, accuracy: 0.0005, "input \(String(reflecting: row.input))")
            default:
                XCTFail("input \(String(reflecting: row.input)): expected \(String(describing: row.seconds)), got \(String(describing: actual))")
            }
        }
    }

    /// Every `updated` value in the shipped registry decodes to the instant
    /// an independent RFC 3339 parser reads from the same string.
    func testFromData_BundledRegistry_EveryUpdatedDateMatchesRFC3339() throws {
        let data = try XCTUnwrap(BundledRegistrySnapshot.load(), "bundled_registry.json missing from the app bundle")
        let catalogs = try OPDS2CatalogsFeed.fromData(data).catalogs

        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawCatalogs = try XCTUnwrap(raw["catalogs"] as? [[String: Any]])
        let rawUpdated = rawCatalogs.map { ($0["metadata"] as? [String: Any])?["updated"] as? String }
        XCTAssertEqual(catalogs.count, rawUpdated.count)
        XCTAssertGreaterThan(rawUpdated.compactMap { $0 }.count, 100, "expected the full bundled registry")

        let reference = ISO8601DateFormatter()
        for (catalog, string) in zip(catalogs, rawUpdated) {
            XCTAssertEqual(catalog.metadata.updated, string.flatMap(reference.date(from:)),
                           "updated \(String(describing: string)) for \(catalog.metadata.id)")
        }
    }

    /// Decodes running on many threads at once, mixing plain and fractional
    /// dates, all read the same values as a serial decode.
    func testFromData_ConcurrentDecodes_AgreeWithSerialDecode() throws {
        let inputs = ["2026-04-15T10:00:00Z", "2026-04-15T10:00:00.123Z", "2026-04-15T05:00:00-05:00", "bad"]
        let payloads = try inputs.map(Self.feedJSON(updated:))
        let expected = try inputs.map(Self.decodedSeconds)

        let iterations = 400
        let results = UnsafeMutableBufferPointer<Double?>.allocate(capacity: iterations)
        defer { results.deallocate() }
        let buffer = results
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let feed = try? OPDS2CatalogsFeed.fromData(payloads[index % payloads.count])
            buffer[index] = feed?.catalogs.first?.metadata.updated?.timeIntervalSince1970
        }

        for index in 0..<iterations {
            XCTAssertEqual(results[index], expected[index % inputs.count], "iteration \(index)")
        }
    }

    /// Parsing the shipped registry's `updated` dates costs under 1.35x the rest
    /// of the decode (two parses per date measured about 1.8x, one about 1.0x).
    /// Wall-clock, so it runs only with TEST_RUNNER_PALACE_TIMING_TESTS=1; see
    /// docs/architecture/testing-rules-rationale.md, "Load-sensitive tests".
    func testFromData_BundledRegistry_DateParsingCostsUnderOneAndAThirdOfTheRest() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PALACE_TIMING_TESTS"] == "1",
                          "wall-clock comparison; set TEST_RUNNER_PALACE_TIMING_TESTS=1 to run")
        let data = try XCTUnwrap(BundledRegistrySnapshot.load(), "bundled_registry.json missing from the app bundle")
        let withoutDates = try Self.removingUpdated(from: data)

        var bestWith = Double.infinity
        var bestWithout = Double.infinity
        for _ in 0..<5 {
            bestWith = min(bestWith, try Self.seconds { _ = try OPDS2CatalogsFeed.fromData(data) })
            bestWithout = min(bestWithout, try Self.seconds { _ = try OPDS2CatalogsFeed.fromData(withoutDates) })
        }

        let dateCost = bestWith - bestWithout
        print("OPDS2CatalogsFeed registry decode: with dates \(bestWith)s, without \(bestWithout)s")
        XCTAssertLessThan(dateCost, bestWithout * 1.35,
                          "with dates \(bestWith)s, without \(bestWithout)s")
    }

    private static func removingUpdated(from data: Data) throws -> Data {
        var feed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let catalogs = try XCTUnwrap(feed["catalogs"] as? [[String: Any]])
        feed["catalogs"] = catalogs.map { catalog -> [String: Any] in
            var catalog = catalog
            var metadata = catalog["metadata"] as? [String: Any] ?? [:]
            metadata.removeValue(forKey: "updated")
            catalog["metadata"] = metadata
            return catalog
        }
        return try JSONSerialization.data(withJSONObject: feed)
    }

    private static func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}
