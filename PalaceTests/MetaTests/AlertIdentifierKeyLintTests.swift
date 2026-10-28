//  AlertIdentifierKeyLintTests.swift
//
//  A localization key that is an identifier rather than English resolves to
//  itself: Palace ships no `en.lproj/Localizable.strings`, so a key absent from
//  the four translated tables reaches the patron verbatim. Ten did.
//
//  Two scans, because the class has two source forms. A declaration without
//  `value:` is the one all ten arrived as; a bare literal at an alert-builder
//  call is the form eight of them took at the call site, including the one in a
//  `#else` (noDRM) arm that the only test target does not compile — which is
//  why these are text scans and not behavioural tests.
//

import XCTest
@testable import Palace

final class AlertIdentifierKeyLintTests: XCTestCase {

    /// The shape predicate, shared with `AlertTextLocalizationTests`, which
    /// carries its self-tests. Two copies drifted once already: the one deleted
    /// from `AccountDetailViewModelTests` had lost the dotted-namespace branch.
    static func isIdentifierShaped(_ text: String) -> Bool {
        AlertTextLocalizationTests.isIdentifierShaped(text)
    }

    /// Both entry points that localize their `title:`/`message:`.
    /// `alertWithDetails` routes to `alert(title:message:)`
    /// (TPPAlertUtils.swift:503-505), so its arguments go through the same
    /// `NSLocalizedString`. Anchoring on `alert(` alone named a census this
    /// did not perform.
    static let localizingBuilders = ["TPPAlertUtils.alert(",
                                     "TPPAlertUtils.alertWithDetails("]

    /// Every identifier-shaped literal passed as `title:` or `message:` to an
    /// alert builder call in `source`, as "label: literal", in source order.
    ///
    /// Scans the balanced-paren argument region of each call rather than the
    /// line, because the builder is almost always called across several lines
    /// and a per-line predicate would only ever see the first argument.
    /// Comments go first, so prose about a key is not a key.
    static func identifierKeyArguments(in source: String) -> [String] {
        var found: [(Int, String)] = []
        let code = stripComments(source)

        for anchor in localizingBuilders {
        var cursor = code.startIndex
        while let call = code.range(of: anchor, range: cursor..<code.endIndex) {
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
            let order = code.distance(from: code.startIndex, to: call.lowerBound)
            for label in ["title:", "message:"] {
                var scan = args.startIndex
                while let at = args.range(of: label, range: scan..<args.endIndex) {
                    scan = at.upperBound
                    // An argument label starts after `(`, `,` or whitespace.
                    // Matching the bare substring made `subtitle:` report as
                    // `title:`.
                    if at.lowerBound > args.startIndex {
                        let before = args[args.index(before: at.lowerBound)]
                        guard before == "(" || before == "," || before.isWhitespace else { continue }
                    }
                    let rest = args[at.upperBound...].drop(while: { $0.isWhitespace })
                    guard rest.first == "\"" else { continue }
                    let body = rest.dropFirst()
                    guard let end = body.firstIndex(of: "\"") else { continue }
                    let literal = String(body[body.startIndex..<end])
                    if isIdentifierShaped(literal) {
                        found.append((order, "\(label) \"\(literal)\""))
                    }
                }
            }
        }
        }
        return found.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// `source` with line and block comments blanked, keeping every newline so
    /// offsets stay comparable. A `//` or `/*` inside a string literal is not a
    /// comment: a `/* */` quoting the pre-fix call would otherwise redden the
    /// census, and 19 files under `Palace/` contain `/*`.
    static func stripComments(_ source: String) -> String {
        var out = ""
        var inString = false, inLine = false, inBlock = false
        var i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i) < source.endIndex ? source[source.index(after: i)] : nil
            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
                i = source.index(after: i)
                continue
            }
            if inBlock {
                if c == "*" && next == "/" {
                    inBlock = false
                    i = source.index(i, offsetBy: 2)
                    continue
                }
                if c == "\n" { out.append(c) }
                i = source.index(after: i)
                continue
            }
            if inString {
                out.append(c)
                if c == "\\", let n = next {
                    out.append(n)
                    i = source.index(i, offsetBy: 2)
                    continue
                }
                if c == "\"" { inString = false }
                i = source.index(after: i)
                continue
            }
            if c == "\"" { inString = true; out.append(c); i = source.index(after: i); continue }
            if c == "/" && next == "/" { inLine = true; i = source.index(i, offsetBy: 2); continue }
            if c == "/" && next == "*" { inBlock = true; i = source.index(i, offsetBy: 2); continue }
            out.append(c)
            i = source.index(after: i)
        }
        return out
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

    /// A literal key written straight into an alert-builder argument. Covers
    /// the `#else` noDRM arm of `TPPSignInBusinessLogic.performLogOut()`, whose
    /// substitution no behavioural test can reach: the DRM scheme does not
    /// compile it and there is no noDRM test target, so reverting those two
    /// arguments to literals reddens this and nothing else.
    ///
    /// Scope: a literal in `title:`/`message:` at a call written as
    /// `TPPAlertUtils.alert(` or `.alertWithDetails(` on one line. A key held
    /// in a variable, a raw string and a receiver split across lines are all
    /// outside it, each pinned below as a known limit.
    /// `testNoDeclarationUsesAnIdentifierKeyWithoutAValue` is the scan that
    /// matches the defect class rather than this one call-site form.
    func testNoAlertCallSitePassesAnIdentifierShapedLiteral() throws {
        let files = try productionSwiftFiles()
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")

        var violators: [String] = []
        var matchedCalls = 0
        var unreadable: [String] = []
        for url in files {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            let code = Self.stripComments(src)
            for anchor in Self.localizingBuilders {
                matchedCalls += code.components(separatedBy: anchor).count - 1
            }
            for hit in Self.identifierKeyArguments(in: src) {
                violators.append("\(url.lastPathComponent): \(hit)")
            }
        }

        // Without this the test cannot tell a clean tree from a marker that
        // matched nothing: renaming the builder, wrapping it, or writing
        // `Self.alert(` would leave it green forever over an unguarded class.
        // 34 occurrences today; the floor is deliberately well under that so
        // ordinary churn does not move it.
        XCTAssertGreaterThan(matchedCalls, 20,
                             "the scan matched \(matchedCalls) builder calls — the marker in "
                             + "`localizingBuilders` has stopped matching the tree")
        XCTAssertEqual(unreadable, [], "could not decode: \(unreadable)")

        XCTAssertTrue(
            violators.isEmpty,
            "the alert builder localizes its arguments, so an identifier-shaped literal "
            + "reaches the patron verbatim. Pass a `Strings` constant carrying `value:`. "
            + "Violators: \(violators)"
        )
    }

    /// Every `NSLocalizedString` whose key is identifier-shaped and which
    /// supplies no `value:`, as "file: key".
    ///
    /// This is the defect class itself. All ten keys this branch fixed were
    /// declared this way — as `Strings.Error` members — and reached the builder
    /// through a constant, which the call-site scan above cannot see.
    static func identifierKeysWithoutAValue(in source: String) -> [String] {
        let code = stripComments(source)
        var out: [String] = []
        var cursor = code.startIndex
        while let call = code.range(of: "NSLocalizedString(", range: cursor..<code.endIndex) {
            cursor = call.upperBound
            let rest = code[call.upperBound...].drop(while: { $0.isWhitespace })
            guard rest.first == "\"" else { continue }
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { continue }
            let key = String(body[body.startIndex..<end])
            guard isIdentifierShaped(key) else { continue }
            // The argument region, to ask whether a `value:` sits in it.
            var depth = 1
            var i = call.upperBound
            var inString = false
            while i < code.endIndex, depth > 0 {
                let c = code[i]
                if inString {
                    if c == "\\" { i = code.index(after: i) }
                    else if c == "\"" { inString = false }
                } else if c == "\"" { inString = true }
                else if c == "(" { depth += 1 }
                else if c == ")" { depth -= 1 }
                if depth == 0 { break }
                i = code.index(after: i)
            }
            let args = code[call.upperBound..<min(i, code.endIndex)]
            if !args.contains("value:") { out.append(key) }
        }
        return out
    }

    /// A new `Strings` member written as
    /// `NSLocalizedString("SomeNewKey", comment: "")` reaches the patron as
    /// `SomeNewKey` in all five languages; adding `value:` is the fix.
    func testNoDeclarationUsesAnIdentifierKeyWithoutAValue() throws {
        let files = try productionSwiftFiles()
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")

        var violators: [String] = []
        var matchedCalls = 0
        for url in files {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = Self.stripComments(src)
            matchedCalls += code.components(separatedBy: "NSLocalizedString(").count - 1
            for key in Self.identifierKeysWithoutAValue(in: src) {
                violators.append("\(url.lastPathComponent): \"\(key)\"")
            }
        }

        XCTAssertGreaterThan(matchedCalls, 100,
                             "the scan matched \(matchedCalls) NSLocalizedString calls — "
                             + "the marker has stopped matching the tree")
        XCTAssertTrue(
            violators.isEmpty,
            "an identifier-shaped key with no `value:` resolves to itself, because Palace "
            + "ships no en.lproj/Localizable.strings. Add `value:` with the English copy. "
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

    /// `alertWithDetails` funnels into `alert(title:message:)`, so its
    /// arguments are localized identically. Anchoring on `alert(` alone left
    /// this shape unscanned while the test claimed a census.
    func testScannerCoversTheSecondBuilder() {
        let withDetails = """
        let a = TPPAlertUtils.alertWithDetails(title: "SettingsAccountViewControllerLogoutFailed",
                                               message: "Please try again later.",
                                               error: err)
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: withDetails),
                       ["title: \"SettingsAccountViewControllerLogoutFailed\""])
    }

    /// `subtitle:` is not `title:`. Matching the bare substring reported it as
    /// one, which would have failed the census on a label the builder does not
    /// localize.
    func testScannerDoesNotMatchALabelThatMerelyEndsInTitle() {
        let sub = """
        let a = TPPAlertUtils.alert(title: Strings.Error.tryAgain, subtitle: "CatalogLaneHeader")
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: sub), [])
    }

    /// A block comment quoting the pre-fix call must not redden the census.
    /// 19 files under `Palace/` contain `/*`.
    func testScannerIgnoresABlockCommentedCall() {
        let commented = """
        /*
         The old form was:
         TPPAlertUtils.alert(title: "SettingsAccountViewControllerCannotLogOutTitle",
                             message: "SettingsAccountViewControllerCannotLogOutMessage")
         */
        let a = TPPAlertUtils.alert(title: Strings.Error.cannotSignOutTitle, message: nil)
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: commented), [])
    }

    /// Tab and carriage return count as whitespace between the label and the
    /// literal. No file under `Palace/` uses either today, so this is a latent
    /// shape pinned before it arrives.
    func testScannerAcceptsTabAndCarriageReturnAsSeparators() {
        let odd = "let a = TPPAlertUtils.alert(title:\t\"SettingsAccountViewControllerLogoutFailed\",\r\n"
            + "                            message:\r\n\t\"SettingsAccountViewControllerCannotLogOutTitle\")\n"
        XCTAssertEqual(Self.identifierKeyArguments(in: odd),
                       ["title: \"SettingsAccountViewControllerLogoutFailed\"",
                        "message: \"SettingsAccountViewControllerCannotLogOutTitle\""])
    }

    // MARK: - Known limits
    //
    // Pinned, not fixed: each is a shape the call-site scan does not see, and
    // writing them down is what keeps the test's claim the size of its reach.
    // The declaration scan covers the first of them, which is the form all ten
    // keys actually took.

    func testScannerDoesNotSeeAKeyHeldInAVariable_knownLimit() {
        let viaVariable = """
        let t = "SettingsAccountViewControllerLogoutFailed"
        let a = TPPAlertUtils.alert(title: t, message: nil)
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: viaVariable), [],
                       "a variable is outside the call-site scan; the declaration scan is "
                       + "what covers a key written once and passed by name")
        XCTAssertEqual(Self.identifierKeysWithoutAValue(in: viaVariable), [],
                       "and a bare `let` is not an NSLocalizedString, so neither scan claims it")
    }

    func testScannerDoesNotSeeARawStringKey_knownLimit() {
        let raw = """
        let a = TPPAlertUtils.alert(title: #"SettingsAccountViewControllerLogoutFailed"#, message: nil)
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: raw), [],
                       "`#\"` is not scanned; 44 raw strings exist under Palace/, none in an "
                       + "alert argument")
    }

    func testScannerDoesNotSeeAReceiverSplitAcrossLines_knownLimit() {
        let split = """
        let a = TPPAlertUtils
            .alert(title: "SettingsAccountViewControllerLogoutFailed", message: nil)
        """
        XCTAssertEqual(Self.identifierKeyArguments(in: split), [],
                       "the marker is the receiver and the method together; the matched-call "
                       + "floor in the census is what catches the marker going stale")
    }

    // MARK: - The declaration scan

    func testDeclarationScanFindsAnIdentifierKeyWithNoValue() {
        let bare = """
        static let cannotSignOutTitle = NSLocalizedString("SettingsAccountViewControllerCannotLogOutTitle", comment: "")
        """
        XCTAssertEqual(Self.identifierKeysWithoutAValue(in: bare),
                       ["SettingsAccountViewControllerCannotLogOutTitle"])
    }

    func testDeclarationScanPassesAKeyThatCarriesAValue() {
        let fixed = """
        static let cannotSignOutTitle = NSLocalizedString(
            "SettingsAccountViewControllerCannotLogOutTitle",
            value: "Logout Failed",
            comment: "Title of the alert shown when sign-out is refused")
        """
        XCTAssertEqual(Self.identifierKeysWithoutAValue(in: fixed), [])
    }

    func testDeclarationScanPassesAProseKey() {
        let prose = """
        static let tryAgain = NSLocalizedString("Please try again later.", comment: "")
        static let ok = NSLocalizedString("OK", comment: "")
        """
        XCTAssertEqual(Self.identifierKeysWithoutAValue(in: prose), [],
                       "English prose is the house idiom and needs no value:")
    }

}
