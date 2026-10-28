//
//  LoanStillHeldWriterLintTests.swift
//
//  Holds the census of sites that announce a completed download via
//  `markDownloadSuccessful(for:`, so a new one cannot be added without asking
//  whether the patron still holds the book. Direct `setState(.downloadSuccessful`
//  writers are OUTSIDE this census; the four that exist are guarded by other
//  means. Not "every site that could".
//

import XCTest
@testable import Palace

final class LoanStillHeldWriterLintTests: XCTestCase {

    /// The guard, in each form a call site may use.
    ///
    /// `mayStoreFetchedContent` is the predicate itself;
    /// `completedDownloadMayBeStored` and the `.discardedNotHeld` outcome both
    /// delegate to it. A site that reaches the question through any of the
    /// three has asked it.
    static let guardTokens = [
        "mayStoreFetchedContent",
        "completedDownloadMayBeStored",
        "discardedNotHeld"
    ]

    // MARK: - lexing

    /// Every line with comments and string-literal contents removed, lexed as a
    /// FILE rather than line by line.
    ///
    /// The FILE-scope signature is load-bearing. A per-line sanitiser cannot see
    /// any shape that spans lines, so a multi-line `/* */` whose interior names a
    /// guard token satisfies the scan, and a `"""` body full of CSS braces moves
    /// the brace arithmetic. Both are prose being read as code — the same class
    /// deleted guard's leftover comment satisfying its own token, now at file
    /// scope. Carrying `inBlockComment` and `inMultilineString` across lines is
    /// what makes those shapes reachable at all.
    ///
    /// This is NOT a Swift parser and does not need to be: it answers one
    /// question — which characters on this line are code — and every construct
    /// below either strips to nothing or survives as itself.
    static func codeOnly(lines: [String]) -> [String] {
        var inBlockComment = false
        var inMultilineString = false
        var out: [String] = []

        for line in lines {
            var code = ""
            let chars = Array(line)
            var i = 0

            while i < chars.count {
                if inBlockComment {
                    if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                        inBlockComment = false
                        i += 2
                    } else {
                        i += 1
                    }
                    continue
                }
                if inMultilineString {
                    if i + 2 < chars.count + 1, matches(chars, at: i, "\"\"\"") {
                        inMultilineString = false
                        i += 3
                    } else {
                        i += 1
                    }
                    continue
                }
                // A raw string's delimiter count decides where it ends, and a
                // backslash inside one escapes nothing.
                if chars[i] == "#" {
                    var hashes = 0
                    var j = i
                    while j < chars.count, chars[j] == "#" { hashes += 1; j += 1 }
                    if j < chars.count, chars[j] == "\"" {
                        i = skipRawString(chars, from: j + 1, hashes: hashes)
                        continue
                    }
                }
                if matches(chars, at: i, "\"\"\"") {
                    inMultilineString = true
                    i += 3
                    continue
                }
                if chars[i] == "\"" {
                    i = skipString(chars, from: i + 1)
                    continue
                }
                if chars[i] == "/", i + 1 < chars.count {
                    if chars[i + 1] == "/" { break }                 // line comment
                    if chars[i + 1] == "*" { inBlockComment = true; i += 2; continue }
                }
                code.append(chars[i])
                i += 1
            }
            out.append(code)
        }
        return out
    }

    /// Single-line convenience, for the unit tests below. Production callers use
    /// the file-level form; this one starts with clean state by construction, so
    /// a cross-line shape is correctly NOT visible to it.
    static func codeOnly(_ line: String) -> String {
        codeOnly(lines: [line])[0]
    }

    private static func matches(_ chars: [Character], at index: Int, _ token: String) -> Bool {
        let t = Array(token)
        guard index + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[index + k] != t[k] { return false }
        return true
    }

    /// Index just past the closing quote, or end of line for an unterminated
    /// literal. A normal string does not span lines in Swift, so running off the
    /// end is the correct stopping point.
    private static func skipString(_ chars: [Character], from start: Int) -> Int {
        var i = start
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "\"" { return i + 1 }
            i += 1
        }
        return chars.count
    }

    private static func skipRawString(_ chars: [Character], from start: Int, hashes: Int) -> Int {
        var i = start
        while i < chars.count {
            if chars[i] == "\"" {
                var seen = 0
                var j = i + 1
                while j < chars.count, chars[j] == "#" { seen += 1; j += 1 }
                if seen >= hashes { return j }
            }
            i += 1
        }
        return chars.count
    }

    // MARK: - predicates, over SANITIZED code

    /// Both predicates take already-sanitized code rather than a raw line, so
    /// the corpus scan and the unit tests cannot diverge the moment one of them
    /// learns about file state.
    static func asksTheQuestion(code: String) -> Bool {
        guardTokens.contains(where: { code.contains($0) })
    }

    /// A declaration reads `markDownloadSuccessful(for book: TPPBook)`, which
    /// does NOT contain `markDownloadSuccessful(for:` — so declarations are
    /// rejected here without needing a clause of their own.
    static func announcesACompletedDownload(code: String) -> Bool {
        code.contains("markDownloadSuccessful(for:")
    }

    // MARK: - scope

    /// Whether a guard on the path to the announcement at `index` asks the
    /// question. Takes SANITIZED lines.
    ///
    /// Walks the enclosing brace chain outward, checking only lines at or above
    /// the announcement's own block level and only lines ABOVE it. A
    /// brace-delimited sibling block's interior is skipped; the line that OPENS
    /// such a block is checked, because `if outcome == .discardedNotHeld { return }`
    /// guards everything after it at the level it sits on.
    ///
    /// Function scope was the first attempt and it was wrong in a way that only
    /// showed under mutation: `fulfillLCPLicense` holds three announce sites, so
    /// the streaming arm's own guard sat above the download-first arm's sites
    /// and covered them. Neutering `if outcome == .discardedNotHeld` left the
    /// census clean — three of four sites resting on one token.
    ///
    /// WHAT THIS DOES NOT HANDLE: any line that CLOSES one block and OPENS
    /// another is brace-neutral, so the walk does not register crossing between
    /// them and a guard in the first arm reads as covering an announcement in
    /// the second. `} else {` is the obvious one; `} else if x {`, `} catch {`
    /// and a one-line sibling arm mask identically. `Palace/` carries 1017
    /// close-then-open lines, 9 of them in the two files under census.
    /// `testAnArmReachedAcrossABraceNeutralLineIsNotDistinguished_knownLimit`
    /// pins the shape. Ignoring `opens` on such a line was tried and
    /// false-positives on the multi-line guards the real callers use. Closing
    /// THIS one means modelling Swift's control structures; the lexing above
    /// needed only file state, and is closed.
    ///
    /// So the claim is narrower than "every arm is independently guarded": a new
    /// announce site in a function with no guard at all fails here, which is the
    /// fifth-writer case this exists for. An arm reached across a brace-neutral
    /// line from an already-guarded one does not.
    static func guardOnThePathAsksTheQuestion(sanitized: [String], index: Int) -> Bool {
        guard index > 0 else { return false }
        var depth = 0
        for i in stride(from: index - 1, through: 0, by: -1) {
            let code = sanitized[i]
            let opens = code.filter { $0 == "{" }.count
            let closes = code.filter { $0 == "}" }.count
            let levelOfLine = depth + closes - opens   // the level this line guards
            if levelOfLine <= 0 && asksTheQuestion(code: code) { return true }
            depth = max(0, levelOfLine)
        }
        return false
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
        ) else {
            return files
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    // MARK: - the census

    /// `markDownloadSuccessful` writes `.downloadSuccessful` and announces a
    /// finished download. A Return leaves the record in the registry at
    /// `.unregistered` rather than removing it, so every lookup a fulfilment
    /// handler makes still succeeds after the loan ends — and the move from
    /// `.unregistered` to `.downloadSuccessful` is not a legal transition.
    ///
    /// Four sites have carried this defect: `BackgroundDownloadHandler`'s two
    /// store paths, `AdobeDRMHandler.handleFulfillmentResult` (#1705), and
    /// `LCPFulfillmentHandler`'s streaming arm. Each was found separately, after
    /// the census that should have named it had been written down as a comment.
    /// The allowlist is deliberately empty: a fifth site fails here.
    func testEveryMarkDownloadSuccessfulCallSiteAsksWhetherTheLoanIsStillHeld() throws {
        let files = try productionSwiftFiles()
        // A lint whose corpus is empty reports a pass. Prove it found the tree.
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")

        var callSites = 0
        var filesWithSites: Set<String> = []
        var violators: [String] = []
        for url in files {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let sanitized = Self.codeOnly(lines: src.components(separatedBy: "\n"))
            for (index, code) in sanitized.enumerated() {
                guard Self.announcesACompletedDownload(code: code) else { continue }
                callSites += 1
                filesWithSites.insert(url.lastPathComponent)
                if Self.guardOnThePathAsksTheQuestion(sanitized: sanitized, index: index) { continue }
                violators.append("\(url.lastPathComponent):\(index + 1): \(code.trimmingCharacters(in: .whitespaces))")
            }
        }

        // Assert the SET of files, not a count: a count floor equal to today's
        // total cannot tell a legitimate removal from a scan that read nothing.
        XCTAssertEqual(
            filesWithSites,
            ["AdobeDRMHandler.swift", "LCPFulfillmentHandler.swift"],
            "the scan must still reach the files that announce; found \(callSites) site(s) in \(filesWithSites.sorted())"
        )
        XCTAssertTrue(
            violators.isEmpty,
            "announcing a completed download for a book whose loan has ended takes "
            + ".unregistered to .downloadSuccessful. Ask mayStoreFetchedContent (directly, "
            + "or through completedDownloadMayBeStored / the .discardedNotHeld outcome) "
            + "first. Violators: \(violators)"
        )
    }

    // MARK: - the predicates themselves

    func testAnnouncePredicateMatchesACallButNotADeclaration() {
        XCTAssertTrue(Self.announcesACompletedDownload(
            code: Self.codeOnly("            delegate?.markDownloadSuccessful(for: book)")))
        XCTAssertFalse(Self.announcesACompletedDownload(
            code: Self.codeOnly("    func markDownloadSuccessful(for book: TPPBook) {")))
        XCTAssertFalse(Self.announcesACompletedDownload(code: Self.codeOnly("let x = 1")))
    }

    /// The defect this lint shipped with for one run: deleting a guard leaves
    /// the comment that explains it, and that comment names the guard's own
    /// token, so a prose-reading scan reports a clean census over the live
    /// defect it exists to catch.
    func testProseNamingTheGuardDoesNotCountAsAsking() {
        XCTAssertFalse(Self.asksTheQuestion(
            code: Self.codeOnly("            // `.discardedNotHeld` outcome that guards the download-first path")))
        XCTAssertFalse(Self.asksTheQuestion(
            code: Self.codeOnly("    /// delegate to it through `completedDownloadMayBeStored`.")))
        // The TRAILING-comment half, pinned on its own: a scan that only
        // rejected whole-line comments answered this one correctly by accident.
        XCTAssertFalse(Self.asksTheQuestion(
            code: Self.codeOnly("        doSomething()  // ask mayStoreFetchedContent before storing")))
        XCTAssertTrue(Self.asksTheQuestion(
            code: Self.codeOnly("            guard LocalBookContentService.mayStoreFetchedContent(")))
        XCTAssertTrue(Self.asksTheQuestion(
            code: Self.codeOnly("            if outcome == .discardedNotHeld { return }  // not held")))
    }

    /// A MULTI-LINE block comment naming a token. Unreachable from a per-line
    /// sanitiser by construction, which is why the signature carries file state.
    func testAMultiLineBlockCommentNamingTheGuardDoesNotCountAsAsking() {
        let sanitized = Self.codeOnly(lines: [
            "    /* why this matters:",
            "       ask mayStoreFetchedContent before storing a finished download",
            "     */",
            "    func newArm() {",
            "        delegate?.markDownloadSuccessful(for: book)",
            "    }"
        ])
        XCTAssertTrue(Self.announcesACompletedDownload(code: sanitized[4]))
        XCTAssertFalse(Self.guardOnThePathAsksTheQuestion(sanitized: sanitized, index: 4),
                       "a paragraph naming the guard is not the guard")
    }

    /// A `"""` body is prose for this purpose too: 336 lines across 20 files are
    /// CSS and JS blobs whose braces would otherwise move the arithmetic.
    func testAMultilineStringBodyIsNotCode() {
        let sanitized = Self.codeOnly(lines: [
            "    func fulfill() {",
            "        if streaming {",
            "            let css = \"\"\"",
            "            .cls { color: red;",
            "            \"\"\"",
            "            guard LocalBookContentService.mayStoreFetchedContent() else { return }",
            "            delegate?.markDownloadSuccessful(for: book)",
            "        }",
            "        if other {",
            "            delegate?.markDownloadSuccessful(for: book)",
            "        }",
            "    }"
        ])
        XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(sanitized: sanitized, index: 6),
                      "the guarded arm is still guarded")
        XCTAssertFalse(Self.guardOnThePathAsksTheQuestion(sanitized: sanitized, index: 9),
                       "an unbalanced brace inside a string body must not reach the sibling arm")
    }

    func testCodeOnlyStripsCommentsAndStringsButNotCode() {
        XCTAssertEqual(Self.codeOnly("if x { // trailing }").trimmingCharacters(in: .whitespaces), "if x {")
        XCTAssertEqual(Self.codeOnly("// whole line {"), "")
        XCTAssertEqual(Self.codeOnly("/* block { */ if y {").trimmingCharacters(in: .whitespaces), "if y {")
        XCTAssertEqual(Self.codeOnly("if a { b() }"), "if a { b() }")
        // A `//` inside a string is not a comment; a quote inside a comment does
        // not open a string. Stripping them in two passes gets both wrong.
        XCTAssertTrue(Self.asksTheQuestion(
            code: Self.codeOnly("let u = \"http://x\"; if o == .discardedNotHeld { return }")))
        XCTAssertFalse(Self.asksTheQuestion(
            code: Self.codeOnly("// he said \"mayStoreFetchedContent\" here")))
        // A raw string's inner quote closes nothing, so the `{` stays inside it.
        XCTAssertFalse(Self.codeOnly("let r = #\"he said \"x { y\" done\"#").contains("{"))
    }

    // MARK: - scope

    /// A guard in a SIBLING function of the same file does not cover this one.
    func testAGuardInASiblingFunctionDoesNotCountAsAsking() {
        let s = Self.codeOnly(lines: [
            "    func guardedPath() {",
            "        guard LocalBookContentService.mayStoreFetchedContent(",
            "            registryState: state, accountUnchanged: true) else { return }",
            "        delegate?.markDownloadSuccessful(for: book)",
            "    }",
            "",
            "    private func unguardedPath() {",
            "        delegate?.markDownloadSuccessful(for: book)",
            "    }"
        ])
        XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 3))
        XCTAssertFalse(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 7),
                       "a guard in a sibling function must not cover this one")
    }

    /// The masking shape, reduced. Under function scope the first arm's guard
    /// covered the second. It must not.
    func testAGuardInAnEarlierSiblingArmDoesNotCoverALaterArm() {
        let s = Self.codeOnly(lines: [
            "    func fulfill() {",
            "        if streaming {",
            "            guard LocalBookContentService.mayStoreFetchedContent() else { return }",
            "            delegate?.markDownloadSuccessful(for: book)",
            "        }",
            "        if other {",
            "            delegate?.markDownloadSuccessful(for: book)",
            "        }",
            "    }"
        ])
        XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 3))
        XCTAssertFalse(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 6),
                       "a sibling arm's guard is not on this arm's path")
    }

    /// The converse the check must not break: a check that returns early at the
    /// enclosing level DOES cover arms nested below it.
    func testAnEarlyReturnAtTheEnclosingLevelCoversNestedArms() {
        let s = Self.codeOnly(lines: [
            "    func fulfill() {",
            "        if outcome == .discardedNotHeld { return }",
            "        if isAudiobook {",
            "            delegate?.markDownloadSuccessful(for: book)",
            "        }",
            "        if isPDF {",
            "            delegate?.markDownloadSuccessful(for: book)",
            "        }",
            "    }"
        ])
        XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 3))
        XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 6))
    }

    /// A guard added after the announcement cannot retroactively cover it.
    func testAGuardBelowTheAnnouncementDoesNotCountAsAsking() {
        let s = Self.codeOnly(lines: [
            "    func fulfill() {",
            "        delegate?.markDownloadSuccessful(for: book)",
            "        guard LocalBookContentService.mayStoreFetchedContent() else { return }",
            "    }"
        ])
        XCTAssertFalse(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 1))
    }

    /// A line that closes one block and opens another is brace-neutral, so the
    /// walk cannot tell the second arm from a continuation of the first. This is
    /// a characterization test: it asserts the CURRENT behaviour so the limit is
    /// visible and measured, across every shape that produces it — not just
    /// `else`. If someone teaches the walk about these, this fails — update it,
    /// do not delete it.
    func testAnArmReachedAcrossABraceNeutralLineIsNotDistinguished_knownLimit() {
        for neutral in ["        } else {",
                        "        } else if other {",
                        "        } catch {"] {
            let s = Self.codeOnly(lines: [
                "    func fulfill() {",
                "        do {",
                "            guard LocalBookContentService.mayStoreFetchedContent() else { return }",
                "            delegate?.markDownloadSuccessful(for: book)",
                neutral,
                "            delegate?.markDownloadSuccessful(for: book)",
                "        }",
                "    }"
            ])
            XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 3),
                          "the first arm is genuinely guarded")
            XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 5),
                          "KNOWN LIMIT: \(neutral.trimmingCharacters(in: .whitespaces)) is brace-neutral, so the second arm is not distinguished")
        }
    }

    /// A brace in prose or in a string must not move the arithmetic.
    func testBracesInCommentsAndStringsDoNotMoveTheWalk() {
        for noise in ["            // doc sample: accessibleWithAnimation {",
                      "            Log.info(\"opening brace { in a message\")"] {
            let s = Self.codeOnly(lines: [
                "    func fulfill() {",
                "        if streaming {",
                noise,
                "            guard LocalBookContentService.mayStoreFetchedContent() else { return }",
                "            delegate?.markDownloadSuccessful(for: book)",
                "        }",
                "        if other {",
                "            delegate?.markDownloadSuccessful(for: book)",
                "        }",
                "    }"
            ])
            XCTAssertFalse(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 7),
                           "a brace in prose must not pull the sibling's guard into scope")
        }
    }

    func testEachDelegatingFormCountsAsAsking() {
        for token in Self.guardTokens {
            let s = Self.codeOnly(lines: [
                "    func somePath() {",
                "        if outcome == .\(token) { return }",
                "        delegate?.markDownloadSuccessful(for: book)",
                "    }"
            ])
            XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(sanitized: s, index: 2),
                          "\(token) must count as asking")
        }
    }
}
