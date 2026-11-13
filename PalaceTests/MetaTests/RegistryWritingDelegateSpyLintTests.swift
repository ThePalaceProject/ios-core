//
//  RegistryWritingDelegateSpyLintTests.swift
//
//  `MyBooksDownloadCenter.markDownloadSuccessful` writes
//  `bookRegistry.setState(.downloadSuccessful, ...)` before it announces. A
//  double that only appends the call to an array cannot observe the state move
//  the handler makes, so a test built on one cannot fail on an illegal
//  transition out of `.unregistered` — the defect such tests exist to catch.
//

import XCTest
@testable import Palace

final class RegistryWritingDelegateSpyLintTests: XCTestCase {

    /// The delegate surfaces whose production implementation writes registry
    /// state. Deliberately a named list rather than a general rule: deciding
    /// "this protocol's production implementation mutates the registry" needs
    /// type resolution that text does not have, and a wider predicate would
    /// flag doubles whose real counterpart only reports.
    static let registryWritingProtocols = ["AdobeDRMHandlerDelegate", "LCPFulfillmentHandlerDelegate"]

    /// The requirement both protocols share, and the write its production
    /// implementation performs.
    static let requirement = "markDownloadSuccessful"
    static let requiredWrite = "setState(.downloadSuccessful"

    // MARK: - Predicates

    /// A type declaration that conforms to one of the registry-writing
    /// protocols, with the offset of its declaration so the scan can read the
    /// body without searching for the name again. Searching by name matched
    /// substrings of unrelated properties.
    struct Conformer {
        let name: String
        let declStart: String.Index
    }

    /// Types declared in `source` that conform to one of `protocols`.
    ///
    /// Matches the conformance clause of a type declaration, so the protocol's
    /// own `protocol X: AnyObject` line and a `weak var delegate: X?` property
    /// are not conformers.
    static func conformers(in source: String, protocols: [String]) -> [Conformer] {
        var found: [Conformer] = []
        var lineStart = source.startIndex
        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            let line = String(source[lineStart..<lineEnd])
            let t = line.trimmingCharacters(in: .whitespaces)
            if let kindRange = declarationKindRange(in: t) {
                let afterKind = t[kindRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if let colon = afterKind.firstIndex(of: ":") {
                    let name = afterKind[afterKind.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                    let conformances = afterKind[afterKind.index(after: colon)...]
                        .replacingOccurrences(of: "{", with: ",")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if !name.isEmpty, !name.contains(" "),
                       conformances.contains(where: { protocols.contains($0) }) {
                        found.append(Conformer(name: name, declStart: lineStart))
                    }
                }
            }
            guard lineEnd < source.endIndex else { break }
            lineStart = source.index(after: lineEnd)
        }
        return found
    }

    /// The range of the `class`/`struct`/`extension` keyword that opens a type
    /// declaration, or nil. `protocol` is excluded on purpose: a protocol
    /// refining another declares a requirement, it does not implement one.
    static func declarationKindRange(in trimmedLine: String) -> Range<String.Index>? {
        for kind in ["class ", "struct ", "extension ", "actor "] {
            guard let r = trimmedLine.range(of: kind) else { continue }
            let head = trimmedLine[trimmedLine.startIndex..<r.lowerBound]
            // Only modifiers may precede the keyword, so `final class` matches
            // and `weak var delegate: AdobeDRMHandlerDelegate?` does not.
            let modifiers = ["final", "private", "fileprivate", "internal", "public", "open", "@MainActor", ""]
            let allModifiers = head
                .split(separator: " ")
                .map(String.init)
                .allSatisfy { modifiers.contains($0) }
            if head.isEmpty || allModifiers { return r }
        }
        return nil
    }

    /// The body of `markDownloadSuccessful` declared inside `typeBody`, or nil
    /// when the type does not declare it.
    static func requirementBody(in typeBody: String, named requirement: String) -> String? {
        guard let r = typeBody.range(of: "func \(requirement)") else { return nil }
        return LintSourceText.braceBody(in: typeBody, from: r.upperBound)
    }

    /// Whether a body performs the registry write its production counterpart does.
    static func writesTheRegistryState(_ body: String) -> Bool {
        body.contains(requiredWrite)
    }

    // MARK: - The production invariant this lint rests on

    /// If production stops writing the state, the requirement on the doubles is
    /// stale and the lint below would be demanding fidelity to something that
    /// no longer happens. Pin the write so the reason fails before the rule.
    func testProductionMarkDownloadSuccessfulStillWritesTheRegistryState() throws {
        let url = LintSourceText.repoRoot
            .appendingPathComponent("Palace/MyBooks/MyBooksDownloadCenter.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let src = LintSourceText.strippingComments(raw)
        guard let r = src.range(of: "func \(Self.requirement)") else {
            return XCTFail("MyBooksDownloadCenter no longer declares \(Self.requirement); "
                           + "this lint's premise is gone and the rule below needs revisiting")
        }
        let body = LintSourceText.braceBody(in: src, from: r.upperBound)
        XCTAssertNotNil(body, "could not read the production body of \(Self.requirement)")
        XCTAssertTrue(
            Self.writesTheRegistryState(body ?? ""),
            "MyBooksDownloadCenter.\(Self.requirement) no longer writes "
            + "\(Self.requiredWrite); either restore the write or retire the spy-fidelity rule"
        )
    }

    // MARK: - Corpus scan

    /// Every test double conforming to a registry-writing delegate must make
    /// the same registry write in `markDownloadSuccessful` that production
    /// makes. A double that only records the call is structurally incapable of
    /// observing an illegal `.unregistered` to `.downloadSuccessful` move.
    func testEveryRegistryWritingDelegateDoubleWritesTheRegistryState() throws {
        let files = LintSourceText.swiftFiles(under: "PalaceTests")
        // A lint whose corpus is empty reports a pass. Prove it read the tree.
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the test sources, found \(files.count)")

        var doublesChecked = 0
        var violators: [String] = []
        for url in files {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let src = LintSourceText.strippingComments(raw)
            for conformer in Self.conformers(in: src, protocols: Self.registryWritingProtocols) {
                guard let body = LintSourceText.braceBody(in: src, from: conformer.declStart) else { continue }
                guard let reqBody = Self.requirementBody(in: body, named: Self.requirement) else { continue }
                doublesChecked += 1
                if !Self.writesTheRegistryState(reqBody) {
                    let lineNo = src[src.startIndex..<conformer.declStart].filter { $0 == "\n" }.count + 1
                    violators.append("\(url.lastPathComponent):\(lineNo) \(conformer.name)")
                }
            }
        }

        // An exact floor, not a guess: four doubles conform today. A rename or
        // a deletion that drops the corpus to zero must fail here rather than
        // report a pass.
        XCTAssertGreaterThanOrEqual(doublesChecked, 4,
                                    "expected at least 4 registry-writing delegate doubles, "
                                    + "found \(doublesChecked); a conformance the scan cannot see "
                                    + "is a conformance this lint does not cover")

        XCTAssertTrue(
            violators.isEmpty,
            "these doubles implement \(Self.requirement) without the "
            + "\(Self.requiredWrite) write that MyBooksDownloadCenter performs, so a test using "
            + "one cannot observe the state transition it is meant to pin. Violators: \(violators)"
        )
    }

    // MARK: - Predicate tests

    /// The conformance predicate must see a double and must not see the
    /// protocol declaration or a property typed by it — the two shapes that
    /// would make this lint either vacuous or noisy.
    func testConformancePredicateFindsDoublesNotDeclarationsOrProperties() {
        let src = """
        private final class SpyDRMDelegate: AdobeDRMHandlerDelegate {
        protocol AdobeDRMHandlerDelegate: AnyObject {
            weak var delegate: AdobeDRMHandlerDelegate?
            init(delegate: AdobeDRMHandlerDelegate? = nil) {
        final class RMSDKHandoffSpy: AdobeDRMHandlerDelegate {
        private final class SpyDelegate: LCPFulfillmentHandlerDelegate {
        extension MyBooksDownloadCenter: LCPFulfillmentHandlerDelegate {}
        """
        XCTAssertEqual(
            Self.conformers(in: src, protocols: Self.registryWritingProtocols).map(\.name),
            ["SpyDRMDelegate", "RMSDKHandoffSpy", "SpyDelegate", "MyBooksDownloadCenter"]
        )
    }

    /// A double conforming to an unrelated delegate is out of scope: the lint
    /// is narrow on purpose.
    func testConformancePredicateIgnoresUnrelatedProtocols() {
        let src = "final class MockBackgroundDownloadDelegate: BackgroundDownloadHandlerDelegate {"
        XCTAssertTrue(Self.conformers(in: src, protocols: Self.registryWritingProtocols).isEmpty)
    }

    /// The fidelity predicate separates a recording body from a writing one,
    /// and reads the requirement's own body rather than the whole type — a
    /// sibling method's write must not vouch for `markDownloadSuccessful`.
    func testFidelityPredicateDistinguishesRecordingFromWriting() {
        let recording = """
            var calls: [String] = []
            func markDownloadSuccessful(for book: TPPBook) {
                calls.append(book.identifier)
            }
        """
        let writing = """
            func markDownloadSuccessful(for book: TPPBook) {
                markedSuccessful.append(book.identifier)
                bookRegistry.setState(.downloadSuccessful, for: book.identifier)
            }
        """
        XCTAssertFalse(Self.writesTheRegistryState(
            Self.requirementBody(in: recording, named: Self.requirement) ?? ""))
        XCTAssertTrue(Self.writesTheRegistryState(
            Self.requirementBody(in: writing, named: Self.requirement) ?? ""))

        // A write in a neighbouring method does not count.
        let misplaced = """
            func reset(for book: TPPBook) {
                bookRegistry.setState(.downloadSuccessful, for: book.identifier)
            }
            func markDownloadSuccessful(for book: TPPBook) {
                calls.append(book.identifier)
            }
        """
        XCTAssertFalse(Self.writesTheRegistryState(
            Self.requirementBody(in: misplaced, named: Self.requirement) ?? ""),
            "the predicate must read the requirement's own body, not the type's")
    }

    /// A commented-out write must not vouch for a recording body. This is the
    /// failure mode that let a census lint go green over a live defect.
    func testACommentedWriteDoesNotSatisfyTheFidelityPredicate() {
        let body = """
            func markDownloadSuccessful(for book: TPPBook) {
                // bookRegistry.setState(.downloadSuccessful, for: book.identifier)
                calls.append(book.identifier)
            }
        """
        XCTAssertTrue(body.contains(Self.requiredWrite),
                      "the fixture must contain the write, or this proves nothing")
        let stripped = LintSourceText.strippingComments(body)
        XCTAssertFalse(Self.writesTheRegistryState(
            Self.requirementBody(in: stripped, named: Self.requirement) ?? ""))
    }

    /// Brace matching must not end the body at a `}` inside a string literal.
    func testBraceBodyIgnoresBracesInStringLiterals() {
        let src = """
        func markDownloadSuccessful(for book: TPPBook) {
            log("}")
            bookRegistry.setState(.downloadSuccessful, for: book.identifier)
        }
        """
        let body = Self.requirementBody(in: src, named: Self.requirement)
        XCTAssertNotNil(body)
        XCTAssertTrue(Self.writesTheRegistryState(body ?? ""))
    }
}
