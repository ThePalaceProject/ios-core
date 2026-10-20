//
//  LoanStillHeldWriterLintTests.swift
//
//  Holds the census of sites that announce a completed download, so a new one
//  cannot be added without asking whether the patron still holds the book.
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
        guard !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") else { return false }
        guard trimmed.contains("markDownloadSuccessful(for:") else { return false }
        return !trimmed.contains("func markDownloadSuccessful")
    }

    /// Whether the function enclosing `index` asks the question anywhere in its
    /// body.
    ///
    /// Scoped to the enclosing function rather than the file on purpose. A
    /// file-wide search is what a prose census amounts to, and it is exactly
    /// wrong here: `LCPFulfillmentHandler` has always guarded its
    /// download-first path, so a file-level check waved its streaming arm
    /// through while that arm took `.unregistered` to `.downloadSuccessful`.
    ///
    /// Only lines ABOVE the announcement count, so a guard added after it
    /// cannot cover it. The residual is a branch added LATER in a function
    /// that already asked for an earlier branch: `fulfillLCPLicense` holds all
    /// three LCP announce sites, so a fourth arm appended there would inherit
    /// the download-first path's `.discardedNotHeld` check without being
    /// covered by it. Narrowing to the innermost brace block would flag the
    /// two arms that legitimately share one check, which is why this stops at
    /// the function. Stated rather than closed.
    static func enclosingFunctionAsksTheQuestion(lines: [String], index: Int) -> Bool {
        var start = index
        while start > 0 {
            let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("func ") || trimmed.contains(" func ") { break }
            start -= 1
        }
        for i in start...index where asksTheQuestion(lines[i]) {
            return true
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
        var violators: [String] = []
        for url in files {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = src.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard Self.announcesACompletedDownload(line) else { continue }
                callSites += 1
                if Self.enclosingFunctionAsksTheQuestion(lines: lines, index: index) { continue }
                violators.append("\(url.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        // A predicate that matched nothing would report a clean census. The
        // known sites are the Adobe handler and the LCP handler's three arms.
        XCTAssertGreaterThanOrEqual(callSites, 4,
                                    "expected to find the known announce sites, found \(callSites)")
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
            "    func unguardedPath() {",
            "        delegate?.markDownloadSuccessful(for: book)",
            "    }"
        ]
        XCTAssertTrue(Self.enclosingFunctionAsksTheQuestion(lines: lines, index: 3),
                      "the guarded function asks on the line above the announcement")
        XCTAssertFalse(Self.enclosingFunctionAsksTheQuestion(lines: lines, index: 7),
                       "a guard in a sibling function must not cover this one")
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
            XCTAssertTrue(Self.enclosingFunctionAsksTheQuestion(lines: lines, index: 2),
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
        XCTAssertFalse(Self.enclosingFunctionAsksTheQuestion(lines: lines, index: 2),
                       "a comment naming the guard is not the guard")
    }
}
