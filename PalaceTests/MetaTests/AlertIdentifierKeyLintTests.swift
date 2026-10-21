//  AlertIdentifierKeyLintTests.swift
//
//  `TPPAlertUtils.alert(title:message:)` localizes its arguments at runtime, so
//  a bare literal there is a localization key. Palace ships no
//  `en.lproj/Localizable.strings`, so a key absent from the four translated
//  tables resolves to itself and the patron reads an identifier. Ten did.
//
//  A text scan, because the arm that motivated it is inside `#else` (noDRM) and
//  the only test target compiles the `#if` side.
//

import XCTest
@testable import Palace

final class AlertIdentifierKeyLintTests: XCTestCase {

    /// True when a patron would read `text` as an identifier rather than as
    /// English. Same rule as `AlertTextLocalizationTests.isIdentifierShaped`,
    /// which carries the self-tests; duplicated rather than shared because that
    /// suite is scoped to resolved alert text and this one to source literals.
    static func isIdentifierShaped(_ text: String) -> Bool {
        guard text.count >= 3, !text.contains(where: { $0.isWhitespace }) else { return false }
        guard text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }),
              let first = text.first, first.isLetter else { return false }
        if text.contains(".") {
            let segments = text.split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count >= 2 else { return false }
            return segments.allSatisfy { segment in
                guard let f = segment.first, f.isLetter else { return false }
                return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            }
        }
        return zip(text, text.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
    }

    /// Every identifier-shaped literal passed as `title:` or `message:` to an
    /// alert builder call in `source`, as "label: literal".
    ///
    /// Scans the balanced-paren argument region of each call rather than the
    /// line, because the builder is almost always called across several lines
    /// and a per-line predicate would only ever see the first argument. Line
    /// comments go first, so prose about a key is not a key.
    static func identifierKeyArguments(in source: String) -> [String] {
        var found: [String] = []
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = String(line)
                guard let hit = text.range(of: "//") else { return text }
                // A `//` inside a string literal is not a comment. An odd count
                // of quotes before it means we are inside one.
                let quotes = text[text.startIndex..<hit.lowerBound].filter { $0 == "\"" }.count
                return quotes % 2 == 0 ? String(text[text.startIndex..<hit.lowerBound]) : text
            }
            .joined(separator: "\n")

        var cursor = code.startIndex
        while let call = code.range(of: "TPPAlertUtils.alert(", range: cursor..<code.endIndex) {
            cursor = call.upperBound
            var depth = 1
            var i = call.upperBound
            var inString = false
            while i < code.endIndex, depth > 0 {
                let c = code[i]
                if inString {
                    if c == "\\" { i = code.index(after: i) }
                    else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                }
                if depth == 0 { break }
                i = code.index(after: i)
            }
            let args = String(code[call.upperBound..<min(i, code.endIndex)])
            for label in ["title:", "message:"] {
                var scan = args.startIndex
                while let at = args.range(of: label, range: scan..<args.endIndex) {
                    scan = at.upperBound
                    let rest = args[at.upperBound...].drop(while: { $0 == " " || $0 == "\n" })
                    guard rest.first == "\"" else { continue }
                    let body = rest.dropFirst()
                    guard let end = body.firstIndex(of: "\"") else { continue }
                    let literal = String(body[body.startIndex..<end])
                    if isIdentifierShaped(literal) {
                        found.append("\(label) \"\(literal)\"")
                    }
                }
            }
        }
        return found
    }

    private func productionSwiftFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MetaTests
            .deletingLastPathComponent()   // PalaceTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Palace")
        var files: [URL] = []
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return files }
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// The census this branch cleared, held cleared. Covers the `#else` noDRM
    /// arm of `TPPSignInBusinessLogic.performLogOut()`, whose substitution no
    /// behavioural test can reach: the DRM scheme does not compile it and there
    /// is no noDRM test target, so reverting those two arguments to literals
    /// reddens this and nothing else.
    func testNoAlertCallSitePassesAnIdentifierShapedLiteral() throws {
        let files = try productionSwiftFiles()
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")

        var violators: [String] = []
        for url in files {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for hit in Self.identifierKeyArguments(in: src) {
                violators.append("\(url.lastPathComponent): \(hit)")
            }
        }

        XCTAssertTrue(
            violators.isEmpty,
            "the alert builder localizes its arguments, so an identifier-shaped literal "
            + "reaches the patron verbatim. Pass a `Strings` constant carrying `value:`. "
            + "Violators: \(violators)"
        )
    }

    // MARK: - The predicate itself
    //
    // Without these the scanner could return nothing on everything, and the
    // census above would pass over a live defect.

    func testScannerFindsTheFormTheNoDRMArmUsedBeforeTheFix() {
        let reverted = """
        if bookRegistry.isSyncing {
            let alert = TPPAlertUtils.alert(
                title: "SettingsAccountViewControllerCannotLogOutTitle",
                message: "SettingsAccountViewControllerCannotLogOutMessage")
        }
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: reverted),
                       ["title: \"SettingsAccountViewControllerCannotLogOutTitle\"",
                        "message: \"SettingsAccountViewControllerCannotLogOutMessage\""])
    }

    func testScannerPassesTheShippedForms() {
        let shipped = """
        let a = TPPAlertUtils.alert(title: Strings.Error.cannotSignOutTitle,
                                    message: Strings.Error.cannotSignOutMessage)
        let b = TPPAlertUtils.alert(title: "Sign Out Failed", message: "Please try again later.")
        // TPPAlertUtils.alert(title: "NotConnected", message: "TimedOut")
        let c = TPPAlertUtils.alert(title: NSLocalizedString("Cancelled", comment: ""), message: nil)
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: shipped), [],
                       "prose, constants, a commented-out call and a single word are all fine")
    }

    func testScannerIgnoresALabelOutsideAnAlertCall() {
        let other = """
        navigate(title: "BookDetailScreen", message: "CatalogLane")
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: other), [],
                       "only the alert builder localizes its arguments")
    }

    /// A `//` inside a string literal is not a comment. Stripping from the
    /// first `//` on the line would have cut this call in half and read the
    /// following lines as its arguments.
    func testScannerKeepsACallWhoseArgumentContainsASlashPair() {
        let withURL = """
        let a = TPPAlertUtils.alert(title: "https://example.org/help",
                                    message: "SettingsAccountViewControllerLogoutFailed")
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: withURL),
                       ["message: \"SettingsAccountViewControllerLogoutFailed\""])
    }

    /// Nested parentheses inside the argument list, and an else-chain after it.
    /// Stopping at the first `)` would end the call early and miss `message:`;
    /// `} else {` is brace-neutral and must not shift the region either.
    func testScannerSpansNestedParenthesesAndAnElseChain() {
        let nested = """
        if flag {
            let a = TPPAlertUtils.alert(title: String(format: fmt, (x + y)),
                                        message: "SettingsAccountViewControllerCannotLogOutMessage")
        } else {
            let b = TPPAlertUtils.alert(title: "TimedOut", message: nil)
        }
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: nested),
                       ["message: \"SettingsAccountViewControllerCannotLogOutMessage\"",
                        "title: \"TimedOut\""])
    }
}
