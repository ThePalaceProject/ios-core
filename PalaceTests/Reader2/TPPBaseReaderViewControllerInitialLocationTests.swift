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

    func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        goCallCount += 1
        lastGoLocator = locator
        onGo?(locator)
        return true
    }
}
