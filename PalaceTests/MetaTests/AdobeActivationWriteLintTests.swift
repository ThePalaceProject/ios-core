//  AdobeActivationWriteLintTests.swift
//
//  PP-5251. The activation record is userID + deviceID + the connector
//  generation that produced them. A production site that writes the identifiers
//  without the generation leaves a device that looks activated under an unknown
//  connector, which the gate in `ensureDeviceActivated` treats as needing
//  migration — so it would re-activate on every Adobe operation, spending an
//  activation slot each time.
//
//  `AdobeActivationAccount` no longer offers the separate setters, so the
//  on-demand path cannot regress. `TPPSignInBusinessLogic+DRM` holds a concrete
//  `TPPUserAccount`, where they are still reachable, and the setters keep
//  legitimate non-activation uses in tests (simulating a second device, for
//  instance). This pins the production boundary instead of removing them.

import XCTest
@testable import Palace

final class AdobeActivationWriteLintTests: XCTestCase {

    private static let declaringFile = "TPPUserAccount.swift"

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

    func testNoProductionFileWritesTheActivationIdentifiersSeparately() throws {
        let files = try productionSwiftFiles()
        // A lint whose corpus is empty reports a pass. Prove it found the tree.
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")

        var violators: [String] = []
        for url in files where url.lastPathComponent != Self.declaringFile {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // `TPPErrorLogger.setUserID` and `Crashlytics.setUserID` are
            // different APIs that happen to share the selector.
            for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                guard text.contains(".setUserID(") || text.contains(".setDeviceID(") else {
                    continue
                }
                if text.contains("TPPErrorLogger") || text.contains("Crashlytics") {
                    continue
                }
                violators.append("\(url.lastPathComponent): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(
            violators.isEmpty,
            "an Adobe activation must be recorded with setAdobeActivation(userID:deviceID:generation:) "
            + "so the connector that produced it is never lost. Violators: \(violators)"
        )
    }

    /// Proves the lint can fail: the predicate it uses must match a line that
    /// looks like the defect.
    func testLintPredicateMatchesASeparateWrite() {
        let offending = "        self.userAccount.setUserID(userID)"
        XCTAssertTrue(offending.contains(".setUserID("))
        XCTAssertFalse(offending.contains("TPPErrorLogger"))
    }

    /// ...and that it does not flag the two APIs that share the selector.
    func testLintPredicateIgnoresTheLoggerAndCrashlytics() {
        XCTAssertTrue("TPPErrorLogger.setUserID(barcode)".contains("TPPErrorLogger"))
        XCTAssertTrue("Crashlytics.crashlytics().setUserID(x)".contains("Crashlytics"))
    }
}
