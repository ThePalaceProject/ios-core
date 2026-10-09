//  AdobeActivationWriteLintTests.swift
//
//  PP-5251. An Adobe activation is userID + deviceID + the connector generation
//  that produced them. This pins that no production site writes the identifiers
//  without the generation; `testNoProductionFileWritesTheActivationIdentifiersSeparately`
//  carries why that matters.
//

import XCTest
@testable import Palace

final class AdobeActivationWriteLintTests: XCTestCase {

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

    /// A production site that writes the identifiers without the generation
    /// leaves a record the gate backfills to `AdobeConnectorGeneration.preMarker`.
    /// That is right for a device activated before the marker existed and wrong
    /// for one activated under a later connector: it would re-activate on every
    /// Adobe operation once `current` moves past `preMarker`, spending an
    /// activation slot each time. The backfill makes this lint matter more, not
    /// less — it is what keeps an absent marker from being silently optimistic.
    ///
    /// `AdobeActivationAccount` no longer offers the separate setters, so the
    /// on-demand path cannot regress. `TPPSignInBusinessLogic+DRM` holds a
    /// concrete `TPPUserAccount`, where they are still reachable, and they keep
    /// legitimate non-activation uses in tests (simulating a second device).
    func testNoProductionFileWritesTheActivationIdentifiersSeparately() throws {
        let files = try productionSwiftFiles()
        // A lint whose corpus is empty reports a pass. Prove it found the tree.
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")

        var violators: [String] = []
        // No file is exempt. Exempting TPPUserAccount.swift bought nothing — its
        // only matching line is TPPErrorLogger.setUserID, which the predicate
        // already skips, and declarations do not match — while hiding a future
        // `self.setUserID(...)` added in the one file where those setters live.
        for url in files {
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
