//
//  LoanStillHeldWriterLintTests.swift
//
//  Holds the census of sites that announce a completed download via
//  `markDownloadSuccessful(for:`, so a new one cannot be added without asking
//  whether the patron still holds the book. Direct `setState(.downloadSuccessful`
//  writers are OUTSIDE this census; the four that exist are guarded by other
//  means. Not "every site that could".
//  `testEveryMarkDownloadSuccessfulCallSiteAsksWhetherTheLoanIsStillHeld`
//  carries why that matters.
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

    /// A line that ASKS the question, as code rather than as prose.
    ///
    /// Comment-blindness is load-bearing, not tidiness. Both handlers explain
    /// the rule in comments that name the delegating forms, and the first
    /// version of this lint read them: deleting the streaming-arm guard left
    /// the explanation behind, the explanation contained `.discardedNotHeld`,
    /// and the lint reported a clean census over a live defect.
    static func asksTheQuestion(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { return false }
        let code = trimmed.components(separatedBy: "//").first ?? trimmed
        return guardTokens.contains(where: { code.contains($0) })
    }

    /// A line that announces a completed download.
    ///
    /// The protocol requirement and the implementation are declarations, not
    /// announcements, and the doc comments in these files quote the selector
    /// while explaining the rule — a predicate that reads prose reports a
    /// violation that is not code.
    static func announcesACompletedDownload(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { return false }
        // A declaration reads `markDownloadSuccessful(for book: TPPBook)`, which
        // does NOT contain `markDownloadSuccessful(for:` — the first guard
        // already rejects it. An explicit `!contains("func …")` clause here was
        // unreachable, and the declaration cases below passed through it
        // vacuously.
        return trimmed.contains("markDownloadSuccessful(for:")
    }

    /// Whether a guard on the path to the announcement at `index` asks the
    /// question.
    ///
    /// Walks the enclosing brace chain outward, checking only lines at or
    /// above the announcement's own block level and only lines ABOVE it. A
    /// sibling block's interior is skipped; the line that OPENS a sibling block
    /// is checked, because `if outcome == .discardedNotHeld { return }` guards
    /// everything after it at the level it sits on.
    ///
    /// Function scope was the first attempt and it was wrong in a way that only
    /// showed under mutation: `fulfillLCPLicense` holds three announce sites, so
    /// the streaming arm's own guard sat above the download-first arm's sites
    /// and covered them. Neutering `if outcome == .discardedNotHeld` left the
    /// census clean — three of the four sites had silently come to rest on one
    /// token. That is the same defect the file-level version had, at a smaller
    /// radius, and it is why this walks blocks rather than counting lines.
    static func guardOnThePathAsksTheQuestion(lines: [String], index: Int) -> Bool {
        guard index > 0 else { return false }
        var depth = 0
        for i in stride(from: index - 1, through: 0, by: -1) {
            let line = lines[i]
            let opens = line.filter { $0 == "{" }.count
            let closes = line.filter { $0 == "}" }.count
            // The level this line sits ON, which is the level it guards.
            let levelOfLine = depth + closes - opens
            if levelOfLine <= 0 && asksTheQuestion(line) { return true }
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

    /// `markDownloadSuccessful` writes `.downloadSuccessful` and announces a
    /// finished download. A Return leaves the record in the registry at
    /// `.unregistered` rather than removing it, so every lookup a fulfilment
    /// handler makes still succeeds after the loan ends — and the move from
    /// `.unregistered` to `.downloadSuccessful` is not a legal transition.
    ///
    /// Four sites have carried this defect: `BackgroundDownloadHandler`'s two
    /// store paths, `AdobeDRMHandler.handleFulfillmentResult` (#1705), and
    /// `LCPFulfillmentHandler`'s streaming arm. Each was found separately,
    /// after the census that should have named it had been written down as a
    /// comment. The allowlist is deliberately empty: a fifth site fails here.
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
            let lines = src.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard Self.announcesACompletedDownload(line) else { continue }
                callSites += 1
                filesWithSites.insert(url.lastPathComponent)
                if Self.guardOnThePathAsksTheQuestion(lines: lines, index: index) { continue }
                violators.append("\(url.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        // A predicate that matched nothing would report a clean census. Assert
        // the SET of files, not a count: a count floor equal to today's total
        // cannot tell a legitimate removal from a scan that read nothing.
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
            "            delegate?.markDownloadSuccessful(for: book)"))
        XCTAssertTrue(Self.announcesACompletedDownload(
            "        delegate.markDownloadSuccessful(for: book)"))
        XCTAssertFalse(Self.announcesACompletedDownload(
            "    func markDownloadSuccessful(for book: TPPBook) {"))
        XCTAssertFalse(Self.announcesACompletedDownload(
            "    func markDownloadSuccessful(for book: TPPBook)"))
        XCTAssertFalse(Self.announcesACompletedDownload("let x = 1"))
    }

    /// The doc comments in both handlers quote the selector while explaining
    /// the rule, so a predicate that reads prose reports the explanation as a
    /// violation.
    func testAnnouncePredicateIgnoresProse() {
        XCTAssertFalse(Self.announcesACompletedDownload(
            "/// streaming-license copy land. `markDownloadSuccessful(for:)` already exists on"))
        XCTAssertFalse(Self.announcesACompletedDownload(
            "// `markDownloadSuccessful(for:)` is internal on MBDC (promoted in"))
    }

    /// The scoping rule, on the shape that defeated the prose census: a guard
    /// in a SIBLING function of the same file does not cover this one.
    func testAGuardInASiblingFunctionDoesNotCountAsAsking() {
        let lines = [
            "    func guardedPath() {",
            "        guard LocalBookContentService.mayStoreFetchedContent(",
            "            registryState: state, accountUnchanged: true) else { return }",
            "        delegate?.markDownloadSuccessful(for: book)",
            "    }",
            "",
            "    private func unguardedPath() {",
            "        delegate?.markDownloadSuccessful(for: book)",
            "    }"
        ]
        XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(lines: lines, index: 3))
        // `private func`, not a bare `func`: a scan that recognised only the
        // bare form widened to file scope for every modifier'd declaration.
        XCTAssertFalse(Self.guardOnThePathAsksTheQuestion(lines: lines, index: 7),
                       "a guard in a sibling function must not cover this one")
    }

    /// The masking shape, reduced. Two arms of one function: the first carries
    /// its own guard, the second does not. Under function scope the first arm's
    /// guard covered the second. It must not.
    func testAGuardInAnEarlierSiblingArmDoesNotCoverALaterArm() {
        let lines = [
            "    func fulfill() {",
            "        if streaming {",
            "            guard LocalBookContentService.mayStoreFetchedContent() else { return }",
            "            delegate?.markDownloadSuccessful(for: book)",
            "        }",
            "        if other {",
            "            delegate?.markDownloadSuccessful(for: book)",
            "        }",
            "    }"
        ]
        XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(lines: lines, index: 3),
                      "the guarded arm asks on the line above its own announcement")
        XCTAssertFalse(Self.guardOnThePathAsksTheQuestion(lines: lines, index: 6),
                       "a sibling arm's guard is not on this arm's path")
    }

    /// The converse, which the fix must not break: a check that returns early
    /// at the enclosing level DOES cover arms nested below it.
    func testAnEarlyReturnAtTheEnclosingLevelCoversNestedArms() {
        let lines = [
            "    func fulfill() {",
            "        if outcome == .discardedNotHeld { return }",
            "        if isAudiobook {",
            "            delegate?.markDownloadSuccessful(for: book)",
            "        }",
            "        if isPDF {",
            "            delegate?.markDownloadSuccessful(for: book)",
            "        }",
            "    }"
        ]
        XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(lines: lines, index: 3))
        XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(lines: lines, index: 6))
    }

    /// Only lines ABOVE the announcement count. A guard added after it cannot
    /// retroactively cover it, and a scan that read the whole block would say
    /// otherwise.
    func testAGuardBelowTheAnnouncementDoesNotCountAsAsking() {
        let lines = [
            "    func fulfill() {",
            "        delegate?.markDownloadSuccessful(for: book)",
            "        guard LocalBookContentService.mayStoreFetchedContent() else { return }",
            "    }"
        ]
        XCTAssertFalse(Self.guardOnThePathAsksTheQuestion(lines: lines, index: 1))
    }

    /// Each delegating form counts. Requiring the predicate's own name would
    /// flag both `BackgroundDownloadHandler` store paths and the LCP
    /// download-first arm, which do ask — through a wrapper.
    func testEachDelegatingFormCountsAsAsking() {
        for token in Self.guardTokens {
            let lines = [
                "    func somePath() {",
                "        if outcome == .\(token) { return }",
                "        delegate?.markDownloadSuccessful(for: book)",
                "    }"
            ]
            XCTAssertTrue(Self.guardOnThePathAsksTheQuestion(lines: lines, index: 2),
                          "\(token) must count as asking")
        }
    }

    /// The defect this lint shipped with for one run. Deleting a guard leaves
    /// the comment that explains it, and that comment names the delegating
    /// forms — so a prose-reading scan reports a clean census over the live
    /// defect it exists to catch.
    func testProseNamingTheGuardDoesNotCountAsAsking() {
        XCTAssertFalse(Self.asksTheQuestion(
            "            // `.discardedNotHeld` outcome that guards the download-first path"))
        XCTAssertFalse(Self.asksTheQuestion(
            "    /// delegate to it through `completedDownloadMayBeStored`."))
        XCTAssertFalse(Self.asksTheQuestion(
            "        // ask mayStoreFetchedContent before storing"))
        XCTAssertTrue(Self.asksTheQuestion(
            "            guard LocalBookContentService.mayStoreFetchedContent("))
        XCTAssertTrue(Self.asksTheQuestion(
            "            if outcome == .discardedNotHeld { return }  // not held"))
        // Pins the TRAILING-comment half on its own. Dropping only the
        // `components(separatedBy: "//")` strip leaves the `hasPrefix("//")`
        // check, which answers this line correctly by accident — so without
        // this case either mechanism alone kept all tests green.
        XCTAssertFalse(Self.asksTheQuestion(
            "        doSomething()  // ask mayStoreFetchedContent before storing"))
    }

    /// The whole lint, end to end, on a function that announces without
    /// asking but carries a comment naming the guard. Proves the corpus scan
    /// — not just the predicate — goes red on the shape that defeated it.
    func testAFunctionGuardedOnlyByACommentIsAViolator() {
        let lines = [
            "    func streamingArm() {",
            "        // short-circuits before the `.discardedNotHeld` outcome below",
            "        delegate?.markDownloadSuccessful(for: book)",
            "    }"
        ]
        XCTAssertTrue(Self.announcesACompletedDownload(lines[2]))
        XCTAssertFalse(Self.guardOnThePathAsksTheQuestion(lines: lines, index: 2),
                       "a comment naming the guard is not the guard")
    }
}
