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
/// `Palace/CarPlay/` goes through it. A direct call elsewhere could omit the
/// completion (the parameter defaults to nil), which no unit test can observe
/// because `CPInterfaceController` cannot be built in a test.
final class CarPlayTemplateCompletionLintTests: XCTestCase {

    private static let carPlayRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MetaTests/
            .deletingLastPathComponent()   // PalaceTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Palace/CarPlay")
    }()

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
        let sources = try carPlaySources()
        XCTAssertNotNil(sources[Self.navigatorFile], "\(Self.navigatorFile) moved; this lint no longer guards anything")

        let offenders = sources.filter { $0.key != Self.navigatorFile }.flatMap { name, lines in
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
