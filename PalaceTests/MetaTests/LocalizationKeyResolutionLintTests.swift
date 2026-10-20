//
//  LocalizationKeyResolutionLintTests.swift
//
//  Palace ships no `en.lproj/Localizable.strings`: the `Localizable.strings`
//  variant group has only es, fr, it and de children, and `developmentRegion`
//  is `en`. So for an English patron `NSLocalizedString(key)` returns `key`
//  verbatim, always. An identifier-shaped key therefore reaches the screen as
//  an identifier unless the call supplies `value:`. PP-5094 shipped that way.
//

import XCTest
@testable import Palace

final class LocalizationKeyResolutionLintTests: XCTestCase {

    // MARK: - Predicates
    //
    // Extracted as statics so the unit tests below exercise THE code the corpus
    // scans use rather than a copy. Inlined, a rename would leave the predicate
    // tests green while the scans passed on everything.

    /// A key a patron would read as an identifier rather than as English.
    ///
    /// The signal is an internal lower-to-upper transition (`NotConnected`,
    /// `SettingsAccountViewControllerLogoutFailed`) or a dotted namespace
    /// (`CarPlay.library`). Single words are prose: `Cancelled` and `Light` read
    /// correctly with no table, which is why the house idiom uses the English
    /// string as the key.
    ///
    /// A dot counts only where it joins two identifier segments. `More...` and
    /// `Loading...` are prose, and reading their ellipsis as a namespace was
    /// this predicate's only false positive over the 535 literal keys.
    static func isIdentifierShaped(_ key: String) -> Bool {
        guard key.count >= 3 else { return false }
        guard !key.contains(where: { $0.isWhitespace }) else { return false }
        let allowed = key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        guard allowed, let first = key.first, first.isLetter else { return false }
        if isDottedNamespace(key) { return true }
        guard !key.contains(".") else { return false }
        return zip(key, key.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
    }

    /// `a.b` / `a.b.c` where every segment starts with a letter.
    static func isDottedNamespace(_ key: String) -> Bool {
        guard key.contains(".") else { return false }
        let segments = key.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { seg in
            guard let f = seg.first, f.isLetter else { return false }
            return seg.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
    }

    /// The key expression of an `NSLocalizedString(` call whose first argument is
    /// not a literal. Such a key cannot be extracted by any tooling, so it can
    /// never be added to a table except by someone noticing by hand.
    static func nonLiteralKeyExpressions(in line: String) -> [String] {
        var found: [String] = []
        var search = line.startIndex
        while let r = line.range(of: "NSLocalizedString(", range: search..<line.endIndex) {
            search = r.upperBound
            var j = r.upperBound
            while j < line.endIndex, line[j] == " " { j = line.index(after: j) }
            guard j < line.endIndex, line[j] != "\"" else { continue }
            var expr = ""
            while j < line.endIndex, line[j] != "," , line[j] != ")" { expr.append(line[j]); j = line.index(after: j) }
            let trimmed = expr.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { found.append(trimmed) }
        }
        return found
    }

    // MARK: - Corpus

    private static var repoRoot: URL { LintSourceText.repoRoot }

    private func productionSwiftFiles() throws -> [URL] {
        LintSourceText.swiftFiles(under: "Palace")
    }

    /// Every key an English patron's bundle can answer.
    ///
    /// That is the `en.lproj` stringsdict and nothing else. The four translated
    /// `Localizable.strings` are deliberately NOT unioned in: a key present in
    /// `fr` but absent from `en` still reaches an English patron as its own
    /// identifier, and counting them hid exactly that — a `CarPlay.library`
    /// with its `value:` removed read as resolvable.
    private func englishResolvableKeys() -> Set<String> {
        let dict = Self.repoRoot
            .appendingPathComponent("Palace/en.lproj/Localizable.stringsdict")
        guard let data = try? Data(contentsOf: dict),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return []
        }
        return Set(plist.keys)
    }

    // MARK: - The premise these scans rest on

    /// The whole file rests on there being no English strings table: the
    /// `Localizable.strings` variant group has only es, fr, it and de children,
    /// so `NSLocalizedString(key)` returns `key` for an English patron. If an
    /// `en.lproj/Localizable.strings` is ever added, English keys resolve
    /// normally and the rules below need rewriting rather than extending.
    func testPalaceShipsNoEnglishLocalizableStringsTable() {
        let en = LintSourceText.repoRoot
            .appendingPathComponent("Palace/en.lproj/Localizable.strings")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: en.path),
            "an en.lproj/Localizable.strings now exists, so an identifier-shaped key is no "
            + "longer necessarily shown as written; revisit this file's rules"
        )
        // The one English table that does exist, and that the scans consult.
        let dict = LintSourceText.repoRoot
            .appendingPathComponent("Palace/en.lproj/Localizable.stringsdict")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dict.path),
                      "expected the en stringsdict to exist; the scans read it for plural keys")
    }

    // MARK: - Corpus scans

    /// Every literal `NSLocalizedString` key must be readable by an English
    /// patron: English prose used as its own key, or an identifier-shaped key
    /// that supplies `value:` for the fallback, or a plural key the `en`
    /// stringsdict answers. There is no `en` strings table to catch anything
    /// else, so a key that satisfies none of these is shown as written.
    func testEveryLocalizedStringLiteralKeyIsReadableByAnEnglishPatron() throws {
        let files = try productionSwiftFiles()
        // A lint whose corpus is empty reports a pass. Prove it read the tree.
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")
        let resolvable = englishResolvableKeys()
        XCTAssertGreaterThanOrEqual(resolvable.count, 11,
                                    "expected the en stringsdict to load, found \(resolvable.count) keys")

        var sites = 0
        var violators: [String] = []
        for url in files {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let src = LintSourceText.strippingComments(raw)
            var search = src.startIndex
            while let r = src.range(of: "NSLocalizedString(", range: search..<src.endIndex) {
                search = r.upperBound
                // Skip leading whitespace and newlines: the house style breaks
                // long calls across lines.
                var j = r.upperBound
                while j < src.endIndex, src[j].isWhitespace { j = src.index(after: j) }
                guard j < src.endIndex, src[j] == "\"" else { continue }
                var key = ""
                var esc = false
                var k = src.index(after: j)
                while k < src.endIndex {
                    let c = src[k]
                    if esc { key.append(c); esc = false } else if c == "\\" { esc = true } else if c == "\"" { break } else { key.append(c) }
                    k = src.index(after: k)
                }
                guard k < src.endIndex else { continue }
                sites += 1
                guard Self.isIdentifierShaped(key) else { continue }
                // `value:` must be the argument right after the key.
                var m = src.index(after: k)
                while m < src.endIndex, src[m].isWhitespace { m = src.index(after: m) }
                var suppliesValue = false
                if m < src.endIndex, src[m] == "," {
                    var n = src.index(after: m)
                    while n < src.endIndex, src[n].isWhitespace { n = src.index(after: n) }
                    suppliesValue = src[n...].hasPrefix("value:") || src[n...].hasPrefix("value :")
                }
                if suppliesValue || resolvable.contains(key) { continue }
                // `strippingComments` replaces each comment byte with one space
                // and keeps newlines, so offsets match the original file and
                // the reported line number is the real one.
                let lineNo = src[src.startIndex..<r.lowerBound].filter { $0 == "\n" }.count + 1
                violators.append("\(url.lastPathComponent):\(lineNo) key \(key)")
            }
        }

        XCTAssertGreaterThan(sites, 400,
                             "expected to find the NSLocalizedString call sites, found \(sites)")
        XCTAssertTrue(
            violators.isEmpty,
            "Palace ships no en.lproj/Localizable.strings, so an identifier-shaped key with no "
            + "value: is shown to an English patron exactly as written. Add value: with the "
            + "English text, or use the English text as the key. Violators: \(violators)"
        )
    }

    /// `NSLocalizedString` with a non-literal key cannot be extracted, so its
    /// key can never be added to a table by tooling. These sites are why the
    /// identifiers above look localized at the point of use.
    ///
    /// An exact census, not a floor: a fourth site must be justified here.
    func testTheUnextractableLocalizationKeyCensusIsUnchanged() throws {
        let files = try productionSwiftFiles()
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")

        var sites: [String] = []
        for url in files {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in LintSourceText.strippingComments(raw).split(separator: "\n", omittingEmptySubsequences: false) {
                for expr in Self.nonLiteralKeyExpressions(in: String(line)) {
                    sites.append("\(url.lastPathComponent): NSLocalizedString(\(expr)")
                }
            }
        }

        let expected = [
            // Every TPPAlertUtils.alert caller's title and message pass through
            // here, so a key reaching the builder is looked up a second time.
            "TPPAlertUtils.swift: NSLocalizedString($0",
            "TPPAlertUtils.swift: NSLocalizedString($0",
            // `localizedTitle` has no callers; 15 of its 16 raw values resolve
            // in no table, so wiring it up would surface identifiers.
            "BookButtonType.swift: NSLocalizedString(self.rawValue"
        ]
        XCTAssertEqual(sites.sorted(), expected.sorted(),
                       "the unextractable-key census changed; a non-literal key cannot be "
                       + "extracted into any table, so a new site needs a reason here")
    }

    // MARK: - Predicate tests

    /// The key the sign-out alert shows today, and the shapes that are prose.
    func testIdentifierShapedMatchesAKeyButNotEnglishProse() {
        XCTAssertTrue(Self.isIdentifierShaped("SettingsAccountViewControllerLogoutFailed"))
        XCTAssertTrue(Self.isIdentifierShaped("NotConnected"))
        XCTAssertTrue(Self.isIdentifierShaped("CarPlay.library"))
        // Single words read correctly with no table, which is the house idiom.
        XCTAssertFalse(Self.isIdentifierShaped("Cancelled"))
        XCTAssertFalse(Self.isIdentifierShaped("Light"))
        XCTAssertFalse(Self.isIdentifierShaped("OK"))
        XCTAssertFalse(Self.isIdentifierShaped("An unknown error occurred while trying to sign out."))
        XCTAssertFalse(Self.isIdentifierShaped("Unexpected Credentials"))
        // An ellipsis is punctuation, not a namespace separator. Reading it as
        // one flagged the two prose keys that do ship with trailing dots.
        XCTAssertFalse(Self.isIdentifierShaped("More..."))
        XCTAssertFalse(Self.isIdentifierShaped("Loading..."))
        XCTAssertTrue(Self.isIdentifierShaped("opds.error.feed_invalid"))
    }

    /// A predicate that reads comments fails in both directions: it reports
    /// prose as a violation, and a guard matching only commented-out text goes
    /// green over live code. Prove the same bytes are ignored as a comment and
    /// flagged as code.
    func testCommentStrippingIgnoresProseButKeepsTheIdenticalCode() {
        let call = "NSLocalizedString(runtimeKey, comment: \"\")"
        let commented = "        // let t = " + call
        XCTAssertTrue(commented.contains("runtimeKey"),
                      "the fixture must contain the key, or this proves nothing")
        XCTAssertTrue(Self.nonLiteralKeyExpressions(
            in: LintSourceText.strippingComments(commented)).isEmpty)

        let code = "        let t = " + call
        XCTAssertEqual(Self.nonLiteralKeyExpressions(in: LintSourceText.strippingComments(code)),
                       ["runtimeKey"])

        // A doc comment spanning the call, and a block comment, are both erased.
        XCTAssertTrue(Self.nonLiteralKeyExpressions(in: LintSourceText.strippingComments(
            "   /// let t = " + call)).isEmpty)
        XCTAssertTrue(Self.nonLiteralKeyExpressions(in: LintSourceText.strippingComments(
            "   /* let t = " + call + " */")).isEmpty)
    }

    /// Comment stripping must not eat a `//` that lives inside a string.
    func testCommentStrippingPreservesStringContents() {
        let line = "        let u = \"https://example.org/x\"  // trailing"
        let stripped = LintSourceText.strippingComments(line)
        XCTAssertTrue(stripped.contains("https://example.org/x"))
        XCTAssertFalse(stripped.contains("trailing"))
        // Line count is preserved so reported line numbers stay true.
        let two = "a // x\nb /* y\nz */ c"
        XCTAssertEqual(LintSourceText.strippingComments(two).filter { $0 == "\n" }.count,
                       two.filter { $0 == "\n" }.count)
    }

    /// The non-literal predicate must see both the named local and the closure
    /// shorthand, and must not fire on a literal key.
    func testNonLiteralKeyPredicateMatchesRuntimeKeysOnly() {
        XCTAssertEqual(Self.nonLiteralKeyExpressions(
            in: "        showError(title: NSLocalizedString(title, comment: \"\"))"), ["title"])
        XCTAssertEqual(Self.nonLiteralKeyExpressions(
            in: "        let t = title.flatMap({ NSLocalizedString($0, comment: \"\") })"), ["$0"])
        XCTAssertTrue(Self.nonLiteralKeyExpressions(
            in: "        let x = NSLocalizedString(\"Sign Out\", comment: \"\")").isEmpty)
    }
}
