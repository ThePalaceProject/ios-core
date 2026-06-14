//
//  TPPBaseReaderViewControllerInitialLocationTests.swift
//  PalaceTests
//
//  P0 #3 (swarm `swarm_f3b9b087`): exercises the gate between
//  `viewDidLoad` and the initial `navigator.go(to:)` call. The fix
//  introduces a `ReaderInitialLocationNavigator` that holds the
//  `initialLocation` and a `ready` latch — `go(to:)` only fires once
//  the latch is tripped (driven from `viewDidAppear` in production,
//  driven directly in tests).
//
//  Behavior-shape test: a stub Navigator records `go(to:)` invocations
//  with their locator. We assert:
//
//   * `go(to:)` is NOT invoked synchronously when the helper is asked
//     to navigate before the ready signal.
//   * `go(to:)` IS invoked exactly once after the ready signal fires.
//   * A second ready signal does NOT trigger a duplicate `go(to:)`.
//   * If the helper is asked for navigation with no initial location,
//     no `go(to:)` ever fires.
//
//  This catches the mutant where the ready-wait is removed and the
//  `Task { navigator.go(...) }` is fired inline — the synchronous-fire
//  assertion (testGate_beforeReady_doesNotInvokeGo) will fail loudly.
//

import XCTest
import ReadiumNavigator
import ReadiumShared
@testable import Palace

@MainActor
final class TPPBaseReaderViewControllerInitialLocationTests: XCTestCase {

    private var stubNavigator: StubInitialLocationNavigator!
    private var sut: ReaderInitialLocationNavigator!

    override func setUp() async throws {
        try await super.setUp()
        stubNavigator = StubInitialLocationNavigator()
    }

    override func tearDown() async throws {
        sut = nil
        stubNavigator = nil
        try await super.tearDown()
    }

    // MARK: - Pre-ready gate

    func testGate_beforeReady_doesNotInvokeGo() async {
        let locator = makeLocator(href: "/chapter1.xhtml", progression: 0.4)
        sut = ReaderInitialLocationNavigator(initialLocation: locator)

        sut.attach(navigator: stubNavigator)
        // No `viewDidAppear()` / no ready signal yet.

        XCTAssertEqual(stubNavigator.goCallCount, 0,
                       "navigator.go(to:) must not fire until the ready signal trips")
    }

    func testGate_afterReady_invokesGoOnce() async {
        let locator = makeLocator(href: "/chapter2.xhtml", progression: 0.6)
        sut = ReaderInitialLocationNavigator(initialLocation: locator)

        sut.attach(navigator: stubNavigator)

        let goCalled = expectation(description: "navigator.go was called")
        stubNavigator.onGo = { _ in goCalled.fulfill() }

        sut.signalReady()
        await fulfillment(of: [goCalled], timeout: 1.0)

        XCTAssertEqual(stubNavigator.goCallCount, 1,
                       "navigator.go(to:) must fire exactly once after the ready signal")
        XCTAssertEqual(stubNavigator.lastGoLocator?.href.string, locator.href.string,
                       "The locator passed to go(to:) must be the initialLocation")
    }

    func testGate_secondReadySignal_doesNotDuplicateGo() async {
        let locator = makeLocator(href: "/chapter3.xhtml", progression: 0.2)
        sut = ReaderInitialLocationNavigator(initialLocation: locator)

        sut.attach(navigator: stubNavigator)

        let goCalled = expectation(description: "navigator.go was called")
        stubNavigator.onGo = { _ in goCalled.fulfill() }

        sut.signalReady()
        await fulfillment(of: [goCalled], timeout: 1.0)

        // Second signalReady — viewDidAppear can fire repeatedly across the
        // lifecycle. We must not navigate again, or the patron's manual
        // page turns would be undone.
        sut.signalReady()

        // Give any spurious Task a tick to land before asserting.
        await Task.yield()

        XCTAssertEqual(stubNavigator.goCallCount, 1,
                       "navigator.go(to:) must NOT fire again on a second ready signal")
    }

    // MARK: - No initial location

    func testGate_noInitialLocation_neverInvokesGo() async {
        sut = ReaderInitialLocationNavigator(initialLocation: nil)

        sut.attach(navigator: stubNavigator)
        sut.signalReady()

        await Task.yield()

        XCTAssertEqual(stubNavigator.goCallCount, 0,
                       "With no initialLocation, navigator.go(to:) must never fire")
    }

    // MARK: - Attach ordering

    func testGate_readyBeforeAttach_navigatesWhenAttachLands() async {
        // viewDidAppear can race ahead of the navigator being installed in
        // exotic VC lifecycles. The latch must survive that ordering —
        // ready-then-attach should still produce exactly one go(to:).
        let locator = makeLocator(href: "/chapter4.xhtml", progression: 0.1)
        sut = ReaderInitialLocationNavigator(initialLocation: locator)

        sut.signalReady()
        // Attach AFTER the ready signal.
        let goCalled = expectation(description: "navigator.go was called")
        stubNavigator.onGo = { _ in goCalled.fulfill() }
        sut.attach(navigator: stubNavigator)

        await fulfillment(of: [goCalled], timeout: 1.0)

        XCTAssertEqual(stubNavigator.goCallCount, 1)
    }

    // MARK: - Sync-dialog double-restore (3.2.0 reading-resume regression)

    /// The dialog-driven sync path feeds a SERVER-sourced cross-device locator
    /// (differs from local) as the reader's `initialLocation`. It restores via the
    /// SAME two paths as a local reopen: the navigator CONSTRUCTOR's
    /// `initialLocation:` (applied DURING WKWebView first-paint) AND the post-paint
    /// gate. A server-shaped locator fails the during-first-paint constructor
    /// restore → Readium "Failed to determine navigation direction for scroll" →
    /// WebContent teardown → the reader bounces back to My Books. EXACTLY ONE
    /// restore must reach the navigator: the post-paint gate is the single restore
    /// authority; the constructor restore must be nil.
    func testSyncRestore_serverShapedLocator_exactlyOneRestoreReachesNavigator() async {
        let serverLocator = makeLocator(href: "/chapter12.xhtml", progression: 0.73)

        // Restore source #1: the navigator constructor's initialLocation input.
        let constructorRestore =
            TPPEPUBViewController.navigatorConstructorInitialLocation(forSavedLocation: serverLocator)

        // Restore source #2: the post-paint gate, driven with the recording stub.
        sut = ReaderInitialLocationNavigator(initialLocation: serverLocator)
        sut.attach(navigator: stubNavigator)
        let goCalled = expectation(description: "gate go(to:)")
        stubNavigator.onGo = { _ in goCalled.fulfill() }
        sut.signalReady()
        await fulfillment(of: [goCalled], timeout: 1.0)
        let gateRestores = stubNavigator.goCallCount

        let totalRestores = (constructorRestore != nil ? 1 : 0) + gateRestores
        XCTAssertEqual(
            totalRestores, 1,
            "EXACTLY ONE restore must reach the navigator (post-paint gate only). A non-nil "
            + "constructor initialLocation restores a server-shaped locator DURING first-paint "
            + "→ WebContent teardown → reader bounces. Got \(totalRestores) "
            + "(constructor=\(constructorRestore != nil), gate=\(gateRestores)).")
        XCTAssertNil(
            constructorRestore,
            "The EPUB navigator constructor must NOT restore — the post-paint gate is the single authority.")
        XCTAssertEqual(
            stubNavigator.lastGoLocator?.href.string, serverLocator.href.string,
            "The gate (sole authority) restores to the saved/synced locator.")
    }

    /// Never-read book (nil initialLocation): zero restores reach the navigator —
    /// it opens at its natural start. (Confirms the fix doesn't perturb the
    /// already-working never-read path.)
    func testNeverRead_nilLocator_zeroRestoresReachNavigator() async {
        let constructorRestore =
            TPPEPUBViewController.navigatorConstructorInitialLocation(forSavedLocation: nil)

        sut = ReaderInitialLocationNavigator(initialLocation: nil)
        sut.attach(navigator: stubNavigator)
        sut.signalReady()
        await Task.yield()

        let totalRestores = (constructorRestore != nil ? 1 : 0) + stubNavigator.goCallCount
        XCTAssertEqual(totalRestores, 0,
                       "Never-read book must produce zero navigator restores (opens at natural start).")
        XCTAssertNil(constructorRestore)
    }

    /// Failed restore = graceful page-1 degradation, NOT a teardown. When the
    /// post-paint gate `go(to:)` returns false (Readium can't resolve a
    /// cross-device server locator), the gate must (a) fire exactly ONE restore
    /// attempt — no second conflicting `go(to:)` — and (b) record the degradation
    /// (`restoreDidDegradeToStart`) so the position-loss is observable, while the
    /// navigator simply remains at its natural start (the constructor restore is
    /// disabled, so there is nothing to tear down).
    func testGate_goReturnsFalse_recordsPage1Degradation_noSecondRestore() async {
        let serverLocator = makeLocator(href: "/unresolvable.xhtml", progression: 0.95)
        stubNavigator.goResult = false
        sut = ReaderInitialLocationNavigator(initialLocation: serverLocator)
        sut.attach(navigator: stubNavigator)

        let restoreDone = expectation(description: "restore attempt completed")
        sut.onRestoreAttempt = { _ in restoreDone.fulfill() }

        sut.signalReady()
        await fulfillment(of: [restoreDone], timeout: 1.0)

        XCTAssertEqual(stubNavigator.goCallCount, 1,
                       "exactly one restore attempt — a failed restore must not fire a second conflicting go(to:)")
        XCTAssertTrue(sut.restoreDidDegradeToStart,
                      "the gate must record the page-1 degradation when go(to:) returns false")
    }

    /// Successful restore must NOT flag degradation.
    func testGate_goReturnsTrue_doesNotFlagDegradation() async {
        let locator = makeLocator(href: "/chapter5.xhtml", progression: 0.5)
        stubNavigator.goResult = true
        sut = ReaderInitialLocationNavigator(initialLocation: locator)
        sut.attach(navigator: stubNavigator)

        let restoreDone = expectation(description: "restore attempt completed")
        sut.onRestoreAttempt = { _ in restoreDone.fulfill() }

        sut.signalReady()
        await fulfillment(of: [restoreDone], timeout: 1.0)

        XCTAssertFalse(sut.restoreDidDegradeToStart,
                       "a successful restore must not flag a page-1 degradation")
    }

    // MARK: - Helpers

    private func makeLocator(href: String, progression: Double) -> Locator {
        return Locator(
            href: AnyURL(string: href)!,
            mediaType: .xhtml,
            locations: Locator.Locations(
                progression: progression,
                totalProgression: progression
            )
        )
    }
}

// MARK: - Stub Navigator

/// Minimal stub that captures `go(to:)` calls. Conforms only to the slice
/// of Navigator that `ReaderInitialLocationNavigator` needs — see
/// `NavigatorGoTo` protocol in production code.
@MainActor
final class StubInitialLocationNavigator: NavigatorGoTo {
    private(set) var goCallCount = 0
    private(set) var lastGoLocator: Locator?
    var onGo: ((Locator) -> Void)?
    /// Simulate Readium returning false (could not resolve the locator).
    var goResult = true

    func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        goCallCount += 1
        lastGoLocator = locator
        onGo?(locator)
        return goResult
    }
}
