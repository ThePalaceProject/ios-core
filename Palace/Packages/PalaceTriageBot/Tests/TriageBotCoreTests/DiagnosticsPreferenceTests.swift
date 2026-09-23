import XCTest
@testable import TriageBotCore

/// PP-4809 — the "Include diagnostics" setting. When OFF, the gating provider
/// must NOT run the full capture (no logs / network / account), and the setting
/// must persist across provider/preference instances.
final class DiagnosticsPreferenceTests: XCTestCase {

    /// Records whether the full capture was invoked.
    private actor SpyFullProvider: ContextProvider {
        private(set) var captureCount = 0
        let snapshot: ContextSnapshot
        init(snapshot: ContextSnapshot) { self.snapshot = snapshot }
        func captureSnapshot() async -> ContextSnapshot {
            captureCount += 1
            return snapshot
        }
    }

    private struct FixedPreference: DiagnosticsPreference {
        let includeDiagnostics: Bool
    }

    private func fullSnapshot() -> ContextSnapshot {
        ContextSnapshot(
            appVersion: "3.3.0", appBuild: "500", osVersion: "26.4.2", deviceModel: "iPhone17,2",
            libraryName: "Morton", networkState: "wifi",
            recentLogLines: ["[E] secret log"], libraryBarcode: "anon-hash"
        )
    }

    private func minimalSnapshot() -> ContextSnapshot {
        ContextSnapshot(appVersion: "3.3.0", appBuild: "500", osVersion: "26.4.2", deviceModel: "iPhone17,2")
    }

    func testDiagnosticsOff_skipsFullCapture_returnsMinimal() async {
        let spy = SpyFullProvider(snapshot: fullSnapshot())
        let minimal = minimalSnapshot()
        let gating = DiagnosticsGatingContextProvider(
            full: spy,
            minimal: { minimal },
            preference: FixedPreference(includeDiagnostics: false)
        )

        let result = await gating.captureSnapshot()

        let count = await spy.captureCount
        XCTAssertEqual(count, 0, "OFF must not invoke the full capture (no logs/network/account read)")
        XCTAssertTrue(result.recentLogLines.isEmpty, "Minimal snapshot carries no logs")
        XCTAssertNil(result.libraryName, "Minimal snapshot carries no library")
        XCTAssertNil(result.libraryBarcode, "Minimal snapshot carries no barcode")
        XCTAssertEqual(result.appVersion, "3.3.0")
        XCTAssertEqual(result.osVersion, "26.4.2")
    }

    func testDiagnosticsOn_runsFullCapture() async {
        let spy = SpyFullProvider(snapshot: fullSnapshot())
        let gating = DiagnosticsGatingContextProvider(
            full: spy,
            minimal: { self.minimalSnapshot() },
            preference: FixedPreference(includeDiagnostics: true)
        )

        let result = await gating.captureSnapshot()

        let count = await spy.captureCount
        XCTAssertEqual(count, 1, "ON must run the full capture exactly once")
        XCTAssertEqual(result.recentLogLines, ["[E] secret log"], "ON returns the full snapshot")
    }

    // MARK: - Persistence

    func testPreference_defaultsToOn() {
        let suite = UserDefaults(suiteName: "diag.test.\(UUID().uuidString)")!
        let pref = UserDefaultsDiagnosticsPreference(defaults: suite, key: "k")
        XCTAssertTrue(pref.includeDiagnostics, "Default must be ON")
    }

    func testPreference_persistsAcrossInstances() {
        let suiteName = "diag.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!

        let first = UserDefaultsDiagnosticsPreference(defaults: suite, key: "k")
        first.setIncludeDiagnostics(false)

        // A fresh instance on the same store (simulating a new app launch / VM).
        let second = UserDefaultsDiagnosticsPreference(defaults: suite, key: "k")
        XCTAssertFalse(second.includeDiagnostics, "The OFF choice must survive across instances")
    }

    // MARK: - PP-4884: the Settings toggle and the provider share one key

    /// The app-side toggle writes to `UserDefaultsDiagnosticsPreference.defaultsKey`
    /// (via @AppStorage). A default-key preference — the one the factory builds
    /// for the gating provider — must read that exact value back. If the key
    /// constant and the default init drift apart, a patron could flip the switch
    /// and the bot would keep collecting everything; this pins them together.
    func testDefaultKey_isWhatTheDefaultInitReads() {
        let suite = UserDefaults(suiteName: "diag.key.\(UUID().uuidString)")!

        // Simulate the toggle writing OFF under the shared key.
        suite.set(false, forKey: UserDefaultsDiagnosticsPreference.defaultsKey)

        // The provider built with the DEFAULT key must honor it.
        let providerPref = UserDefaultsDiagnosticsPreference(defaults: suite)
        XCTAssertFalse(providerPref.includeDiagnostics,
                       "A toggle write under defaultsKey must be read by the default-key preference")
    }
}
