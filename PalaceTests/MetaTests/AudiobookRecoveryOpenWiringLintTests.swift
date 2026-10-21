//
//  AudiobookRecoveryOpenWiringLintTests.swift
//  PalaceTests
//
//  PP-4973: a recovery that re-opened through the patron entry point was
//  refused by the duplicate-open guard, since the session holds `.loading`
//  while the recovery runs, and the patron sat on the loading shell with no
//  error. Re-opens must name their origin; only the two patron overloads may
//  leave it to the default.
//
//  The census is `AudiobookSessionManager.swift` alone: its six `+` extensions
//  re-open through `reopen(_:because:)` and call the witness nowhere, and the
//  patron entry points in CarPlay, `BookOpenRouter` and `BookDetailViewModel`
//  may omit `origin:`. Not "every site that could".
//

import XCTest
@testable import Palace

final class AudiobookRecoveryOpenWiringLintTests: XCTestCase {

    private static let subject = "Palace/Audiobooks/AudiobookSessionManager.swift"

    /// Every call to `openAudiobook(` in `source`, paired with its argument
    /// text, skipping the `func` declarations. A call's arguments run to the
    /// matching `)` so a call spread over several lines is read whole.
    static func openAudiobookCalls(in source: String) -> [String] {
        var calls: [String] = []
        var search = source.startIndex
        while let hit = source.range(of: "openAudiobook(", range: search..<source.endIndex) {
            search = hit.upperBound
            let lineStart = source[..<hit.lowerBound].lastIndex(of: "\n").map(source.index(after:))
                ?? source.startIndex
            if source[lineStart..<hit.lowerBound].contains("func ") { continue }
            var depth = 1
            var i = hit.upperBound
            var inString = false
            var escaped = false
            while i < source.endIndex, depth > 0 {
                let c = source[i]
                if inString {
                    // A paren inside a literal must not move the depth, or the
                    // argument text ends early and `origin:` reads as absent.
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                i = source.index(after: i)
            }
            calls.append(String(source[hit.upperBound..<i]))
        }
        return calls
    }

    /// The guard itself must be able to fail, or the assertion below is empty.
    func testPredicateFindsAPatronWitnessCallAndSkipsDeclarations() {
        let declaration = "    func openAudiobook(_ book: TPPBook, startPlaying: Bool = true) async -> R {"
        let patronCall = "                        _ = await self.openAudiobook(book, startPlaying: true)"
        let originCall = "        await openAudiobook(book, startPlaying: startPlaying, origin: .patron)"
        let wrapped = "await openAudiobook(\n    book,\n    startPlaying: true,\n    origin: .reopen(.coldLoad))"

        XCTAssertEqual(Self.openAudiobookCalls(in: declaration), [],
                       "a declaration is not a call")
        XCTAssertEqual(Self.openAudiobookCalls(in: patronCall).filter { !$0.contains("origin:") }.count, 1,
                       "the shape this lint exists to catch must be caught")
        XCTAssertEqual(Self.openAudiobookCalls(in: originCall).filter { !$0.contains("origin:") }, [])
        XCTAssertEqual(Self.openAudiobookCalls(in: wrapped).filter { !$0.contains("origin:") }, [],
                       "a call spread over lines is read to its closing paren")

        // The three shapes a hand-rolled scan gets wrong: a paren inside a
        // string literal, a commented-out call, and a brace-neutral else.
        let literal = "await openAudiobook(book, reason: \"retry (second)\", origin: .patron)"
        XCTAssertEqual(Self.openAudiobookCalls(in: literal).filter { !$0.contains("origin:") }, [],
                       "a paren inside a literal ended the argument text early")
        let commented = LintSourceText.strippingComments(
            "        // _ = await self.openAudiobook(book, startPlaying: true)")
        XCTAssertEqual(Self.openAudiobookCalls(in: commented), [],
                       "a commented-out call is not a call")
        let elseChain = "if x { await openAudiobook(b, origin: .patron) } else { _ = await openAudiobook(b) }"
        XCTAssertEqual(Self.openAudiobookCalls(in: elseChain).filter { !$0.contains("origin:") }.count, 1,
                       "an else arm's call must still be read")
    }

    func testEveryOpenInTheSessionManagerNamesItsOrigin() throws {
        let url = LintSourceText.repoRoot.appendingPathComponent(Self.subject)
        let source = LintSourceText.strippingComments(try String(contentsOf: url, encoding: .utf8))

        let calls = Self.openAudiobookCalls(in: source)
        XCTAssertGreaterThan(calls.count, 1,
                             "expected to find the open call sites in \(Self.subject), found \(calls.count)")

        let unnamed = calls.filter { !$0.contains("origin:") }
        XCTAssertTrue(unnamed.isEmpty,
                      "an open that leaves its origin to the patron default is refused by the "
                      + "duplicate-open guard while a recovery holds `.loading`, and the patron "
                      + "is left on the loading shell with no error (PP-4973). Re-open through "
                      + "`reopen(_:because:)`. Offending call(s): \(unnamed)")
    }
}
