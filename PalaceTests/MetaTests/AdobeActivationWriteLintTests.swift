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

    /// A production site deciding whether to skip activation from the
    /// connector's bare verdict. `canUseRecordedActivation` is the only correct
    /// question; three sites asked the bare one when the gate was first added,
    /// and because the shipped generation equals `preMarker` nothing would have
    /// failed at the bump — the migration would just never fire there.
    ///
    /// The declaration, the wrapper's own delegation and the registry's
    /// unrelated `isUserAuthorizedForRegistry` are not decisions.
    static func asksTheBareAuthorizationQuestion(_ line: String,
                                                 inFile fileName: String = "") -> Bool {
        guard line.contains("isUserAuthorized(") else { return false }
        if line.contains("func isUserAuthorized") { return false }
        // Scoped to the file that defines the policy. Unqualified `isUserAuthorized(`
        // compiles exactly inside a `TPPDRMAuthorizing` extension, which is where a
        // new bypass would live — a global exemption would wave it through.
        if fileName == "AdobeConnectorGeneration.swift",
           line.contains("return isUserAuthorized(") {
            return false
        }
        return true
    }

    /// A `canUseRecordedActivation` call that does not pass the account's recorded
    /// generation.
    ///
    /// Routing a site through the predicate is not the same as asking the right
    /// question: substituting `recordedGeneration: AdobeConnectorGeneration.current`
    /// keeps the call, keeps the name, and restores PP-5026 silently. The earlier
    /// lint checked only the method name, which is not where the meaning lives,
    /// and `palace_mutate` emits no argument-substitution mutants — so neither
    /// guard could see it. `shouldSkipAdobeActivation` has behavioural tests;
    /// this covers the call sites that do not.
    static func passesAConstantGeneration(_ line: String) -> Bool {
        guard line.contains("recordedGeneration:") else { return false }
        // A declaration is not a call. The first version of this predicate
        // flagged both parameter declarations and the service wrapper's
        // forward — the lint found shapes I had not considered, which is the
        // lint working, but they are not decisions.
        if line.contains("recordedGeneration: Int?") { return false }
        if line.contains("recordedGeneration: recordedGeneration") { return false }
        return !line.contains("adobeActivationConnectorGeneration")
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

    /// The three bypasses, pinned so they cannot come back.
    func testNoProductionFileDecidesFromTheBareAuthorizationCheck() throws {
        let files = try productionSwiftFiles()
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")

        var violators: [String] = []
        for url in files {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                guard Self.asksTheBareAuthorizationQuestion(
                        text, inFile: url.lastPathComponent) else { continue }
                violators.append("\(url.lastPathComponent): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(
            violators.isEmpty,
            "deciding whether to skip Adobe activation must go through "
            + "canUseRecordedActivation, which also tests the connector generation. "
            + "Violators: \(violators)"
        )
    }

    func testBareAuthorizationPredicateMatchesADecisionButNotADeclaration() {
        XCTAssertTrue(Self.asksTheBareAuthorizationQuestion(
            "   drmAuthorizer.isUserAuthorized(userID, withDevice: deviceID) else {"))
        XCTAssertFalse(Self.asksTheBareAuthorizationQuestion(
            "    func isUserAuthorized(_ userID: String?, deviceID: String?) -> Bool {"))
        XCTAssertFalse(Self.asksTheBareAuthorizationQuestion("let x = 1"))
    }

    /// The policy file's own unqualified call is exempt only THERE. An earlier
    /// version exempted it everywhere, which would have waved through a new
    /// bypass added in any other `TPPDRMAuthorizing` extension.
    func testTheUnqualifiedCallIsExemptOnlyInThePolicyFile() {
        let line = "        return isUserAuthorized(userID, withDevice: deviceID)"
        XCTAssertFalse(Self.asksTheBareAuthorizationQuestion(
            line, inFile: "AdobeConnectorGeneration.swift"))
        XCTAssertTrue(Self.asksTheBareAuthorizationQuestion(
            line, inFile: "SomeOtherAuthorizerExtension.swift"))
    }

    /// `isUserAuthorizedForRegistry` is rejected by the first guard, not by an
    /// exclusion: the substring `isUserAuthorized(` does not occur in it. An
    /// earlier version carried a dead exclusion for it, and the test that
    /// documented that exclusion passed through a different branch.
    func testTheRegistryClosureIsRejectedByTheFirstGuard() {
        XCTAssertFalse("isUserAuthorizedForRegistry(".contains("isUserAuthorized("))
        XCTAssertFalse(Self.asksTheBareAuthorizationQuestion("        if !isUserAuthorizedForRegistry() {"))
    }

    /// Every production site must pass the account's recorded generation, not a
    /// constant. This is the guard the name-only lint could not provide.
    func testEveryProductionCallSitePassesTheRecordedGeneration() throws {
        let files = try productionSwiftFiles()
        XCTAssertGreaterThan(files.count, 100,
                             "expected to walk the production sources, found \(files.count)")

        var violators: [String] = []
        var callSites = 0
        for url in files {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                guard text.contains("recordedGeneration:") else { continue }
                callSites += 1
                if Self.passesAConstantGeneration(text) {
                    violators.append("\(url.lastPathComponent): \(text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        // A lint that finds no call sites reports a pass. There are four:
        // three decision sites plus the service wrapper's own parameter.
        XCTAssertGreaterThanOrEqual(callSites, 4,
                                    "expected the recordedGeneration call sites, found \(callSites)")
        XCTAssertTrue(
            violators.isEmpty,
            "a skip-activation decision must use the account's recorded generation; "
            + "a constant restores PP-5026 while keeping the call shape. Violators: \(violators)"
        )
    }

    func testConstantGenerationPredicateDistinguishesTheTwoForms() {
        XCTAssertTrue(Self.passesAConstantGeneration(
            "        recordedGeneration: AdobeConnectorGeneration.current) else {"))
        XCTAssertTrue(Self.passesAConstantGeneration("   recordedGeneration: 1,"))
        XCTAssertFalse(Self.passesAConstantGeneration(
            "        recordedGeneration: userAccount.adobeActivationConnectorGeneration) else {"))
        XCTAssertFalse(Self.passesAConstantGeneration("let x = 1"))
        // Not decisions: the parameter declaration and the wrapper's forward.
        XCTAssertFalse(Self.passesAConstantGeneration("                recordedGeneration: Int?,"))
        XCTAssertFalse(Self.passesAConstantGeneration(
            "                       recordedGeneration: recordedGeneration)"))
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
