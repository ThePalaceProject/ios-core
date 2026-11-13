//
//  LocalizationTablesTests.swift
//  PalaceTests
//
//  The .strings tables ship as resources, so nothing in the Swift build
//  verifies them. These run inside the app's own suite — `scripts/tests/` is
//  pytest and never executes in the Xcode test job, so a broken table would
//  otherwise reach a release with every check green.
//

import XCTest
@testable import Palace

final class LocalizationTablesTests: XCTestCase {

    private static let languages = ["de", "es", "fr", "it"]

    /// The shipped table for one language, read the way the runtime reads it.
    private func table(_ language: String, file: StaticString = #filePath,
                       line: UInt = #line) -> [String: String]? {
        // TPPAppDelegate is in the APP target; a class from a Swift package
        // would resolve to the package's bundle, not the one shipping the tables.
        let bundle = Bundle(for: TPPAppDelegate.self)
        guard let path = bundle.path(forResource: "Localizable", ofType: "strings",
                                     inDirectory: nil, forLocalization: language) else {
            XCTFail("no Localizable.strings shipped for \(language)", file: file, line: line)
            return nil
        }
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
            XCTFail("\(language) Localizable.strings did not parse", file: file, line: line)
            return nil
        }
        return dict
    }

    func testEveryLanguageShipsATable() {
        for language in Self.languages {
            XCTAssertNotNil(table(language), "\(language) is missing its table")
        }
    }

    func testKeySetsAreIdenticalAcrossLanguages() {
        // Foundation has no per-key fallback: a table that EXISTS but lacks a
        // key returns the key itself, so a partial table is user-visible
        // breakage rather than a quiet gap.
        var sets: [String: Set<String>] = [:]
        for language in Self.languages {
            guard let t = table(language) else { return }
            sets[language] = Set(t.keys)
        }
        guard let reference = sets["de"] else { return XCTFail("no reference table") }
        for (language, keys) in sets where keys != reference {
            let missing = reference.subtracting(keys).sorted().prefix(5)
            let extra = keys.subtracting(reference).sorted().prefix(5)
            XCTFail("\(language) key set differs — missing: \(Array(missing)), extra: \(Array(extra))")
        }
    }

    func testNoValueIsEmpty() {
        for language in Self.languages {
            guard let t = table(language) else { return }
            let blanks = t.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            XCTAssertTrue(blanks.isEmpty, "\(language) has empty values: \(blanks.keys.sorted().prefix(5))")
        }
    }

    func testFormatSpecifierCountMatchesTheKey() {
        // A translation that drops or adds a conversion makes String(format:)
        // read the wrong argument — undefined behaviour in a release build.
        // The key IS the English for most strings, so it is the reference.
        for language in Self.languages {
            guard let t = table(language) else { return }
            for (key, value) in t where key.contains("%") {
                XCTAssertEqual(Self.conversions(in: key), Self.conversions(in: value),
                               "\(language): conversions differ for \(key)")
            }
        }
    }

    /// Conversion specifiers, as a sorted multiset of their type letters.
    /// Positional reordering (`%1$@` / `%2$@`) is legitimate, so position is
    /// deliberately not compared — only which conversions are consumed.
    private static func conversions(in s: String) -> [String] {
        let pattern = "%(?:\\d+\\$)?(?:hh|h|ll|l|q|L|z|t|j)?([@diouxXeEfFgGaAcCsSp])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let stripped = s.replacingOccurrences(of: "%%", with: "")
        let range = NSRange(stripped.startIndex..., in: stripped)
        return re.matches(in: stripped, range: range).compactMap {
            Range($0.range(at: 1), in: stripped).map { String(stripped[$0]) }
        }.sorted()
    }
}
