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

    /// The lint's predicate, extracted so the tests below exercise THIS code
    /// rather than a copy. Inline, it was uncoupled from them: renaming it to
    /// `.setUserId(` left both "predicate" tests green while the corpus scan
    /// passed on everything.
    ///
    /// `TPPErrorLogger.setUserID` and `Crashlytics.setUserID` are unrelated APIs
    /// that happen to share the selector.
    static func isSeparateActivationWrite(_ line: String) -> Bool {
        guard line.contains(".setUserID(") || line.contains(".setDeviceID(") else {
            return false
        }
        return !line.contains("TPPErrorLogger") && !line.contains("Crashlytics")
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

    func testNoProductionFileWritesTheActivationIdentifiersSeparately() throws {
        let files = try productionSwiftFiles()
        // A lint whose corpus is empty reports a pass. Prove it found the tree.
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")

        var violators: [String] = []
        for url in files where url.lastPathComponent != Self.declaringFile {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                guard Self.isSeparateActivationWrite(text) else { continue }
                violators.append("\(url.lastPathComponent): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(
            violators.isEmpty,
            "an Adobe activation must be recorded with setAdobeActivation(userID:deviceID:generation:) "
            + "so the connector that produced it is never lost. Violators: \(violators)"
        )
    }

    /// Proves the lint can fail, by calling the predicate the corpus scan uses.
    func testLintPredicateMatchesASeparateWrite() {
        XCTAssertTrue(Self.isSeparateActivationWrite("        self.userAccount.setUserID(userID)"))
        XCTAssertTrue(Self.isSeparateActivationWrite("        acct.setDeviceID(deviceID)"))
    }

    /// ...and that it does not flag the two unrelated APIs that share the
    /// selector, nor an unrelated line.
    func testLintPredicateIgnoresTheLoggerAndCrashlytics() {
        XCTAssertFalse(Self.isSeparateActivationWrite("TPPErrorLogger.setUserID(barcode)"))
        XCTAssertFalse(Self.isSeparateActivationWrite("Crashlytics.crashlytics().setUserID(x)"))
        XCTAssertFalse(Self.isSeparateActivationWrite("let x = 1"))
    }
}
