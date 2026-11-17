//
//  CarPlayTemplateCompletionLintTests.swift
//  PalaceTests
//
//  PP-5276: CarPlay template operations go through CarPlayTemplateNavigator.
//

import XCTest

/// `CPInterfaceController` raises `NSGenericException` when a template
/// operation fails and its completion is nil (PP-5276). `CarPlayTemplateNavigator`
/// always passes one, so these checks pin that every operation under
/// `Palace/` goes through it. A direct call elsewhere could omit the
/// completion (the parameter defaults to nil), which no unit test can observe
/// because `CPInterfaceController` cannot be built in a test.
final class CarPlayTemplateCompletionLintTests: XCTestCase {

    private static let palaceRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MetaTests/
            .deletingLastPathComponent()   // PalaceTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Palace")
    }()

    private static let carPlayRoot = palaceRoot.appendingPathComponent("CarPlay")

    private static let navigatorFile = "CarPlayTemplateNavigator.swift"

    /// A call of any `CPInterfaceController` template operation. The leading
    /// `.` keeps operation names inside log strings (`"pushTemplate(chapterList)"`)
    /// from matching.
    private static let operationCall = try! NSRegularExpression(
        pattern: #"\.(setRootTemplate|pushTemplate|popTemplate|popToRootTemplate|presentTemplate|dismissTemplate)\s*\("#
    )

    func testNoCarPlayCodePassesANilCompletion() throws {
        let sources = try carPlaySources()

        let offenders = sources.flatMap { name, lines in
            lines.enumerated()
                .filter { !isComment($0.element) && $0.element.contains("completion: nil") }
                .map { "\(name):\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
        }

        XCTAssertEqual(offenders, [], "CarPlay raises NSGenericException when a failing template operation has a nil completion (PP-5276)")
    }

    func testOnlyTheNavigatorCallsTemplateOperations() throws {
        let sources = try swiftSources(under: Self.palaceRoot)
        let navigatorPath = "CarPlay/" + Self.navigatorFile
        XCTAssertNotNil(sources[navigatorPath], "\(navigatorPath) moved; this lint no longer guards anything")

        let offenders = sources.filter { $0.key != navigatorPath }.flatMap { name, lines in
            operationLines(lines).map { "\(name):\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
        }

        XCTAssertEqual(offenders, [], "Route CarPlay template operations through CarPlayTemplateNavigator")
    }

    func testEveryNavigatorTemplateOperationPassesACompletion() throws {
        let lines = try XCTUnwrap(try carPlaySources()[Self.navigatorFile])

        let calls = operationLines(lines).filter { !$0.element.contains("func ") }
        XCTAssertGreaterThanOrEqual(calls.count, 6, "found too few operation calls; the lint has stopped scanning the navigator")

        let missing = calls.filter { !$0.element.contains("completion: Self.completion(") }
        XCTAssertEqual(missing.map { "line \($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }, [])
    }

    // MARK: - Helpers

    private func carPlaySources() throws -> [String: [String]] {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.carPlayRoot.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty, "resolved no Swift files under \(Self.carPlayRoot.path)")
        var sources: [String: [String]] = [:]
        for name in names {
            let text = try String(contentsOf: Self.carPlayRoot.appendingPathComponent(name), encoding: .utf8)
            sources[name] = text.components(separatedBy: .newlines)
        }
        return sources
    }

    /// Every Swift file under `root`, recursively, keyed by path relative to `root`.
    ///
    /// `enumerator(atPath:)` yields paths that are already relative to the root,
    /// which is the whole reason it is used here. Deriving them instead from the
    /// absolute URLs of `enumerator(at:)` required subtracting the root, and that
    /// arithmetic was wrong in two ways at once: `#filePath` records the root as
    /// written at compile time while the enumerator reports it resolved, and the
    /// subtraction used `replacingOccurrences`, which matches anywhere rather
    /// than only at the start. Under a worktree below `/tmp` — a symlink to
    /// `private/tmp` — a root of `/tmp/…/Palace/` matched the reported
    /// `/private/tmp/…/Palace/…` after `/private` and left that as residue, so
    /// every key was mangled, the navigator went unrecognised, and the test
    /// reported its own files as offenders. Relative keys have no root to
    /// subtract and no spelling to agree on.
    private func swiftSources(under root: URL) throws -> [String: [String]] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
        var sources: [String: [String]] = [:]
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            sources[relative] = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
                .components(separatedBy: .newlines)
        }
        XCTAssertGreaterThan(sources.count, 100, "resolved too few Swift files under \(root.path)")
        return sources
    }

    private func operationLines(_ lines: [String]) -> [(offset: Int, element: String)] {
        lines.enumerated().filter { _, line in
            !isComment(line) &&
                Self.operationCall.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }.map { (offset: $0.offset, element: $0.element) }
    }

    private func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("*")
    }
}
