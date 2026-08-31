//
//  ReaderServiceRouteOwnershipTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// PP-5022 — pins the ownership rule the LCP-PDF completions use before popping.
///
/// An LCP open runs for seconds or minutes and finishes asynchronously. The
/// patron can back out of the loading view — which restores the tab bar — and
/// push something else on that same stack before the open lands. Both
/// completion arms (`abortRunawayOpen` and the `openBook` failure arm) used to
/// call `path.removeLast()` unconditionally, which removes the patron's screen
/// rather than the reader route. This is the decision that stops that, and it
/// is the only part of the flow that can be exercised without driving a real
/// Readium publication open.
@MainActor
final class ReaderServiceRouteOwnershipTests: XCTestCase {

    private var service: ReaderService!
    private var coordinator: NavigationCoordinator!
    private let bookId = "lcp-pdf-book"

    override func setUp() {
        super.setUp()
        service = ReaderService()
        coordinator = NavigationCoordinator()
    }

    override func tearDown() {
        service = nil
        coordinator = nil
        super.tearDown()
    }

    /// The ordinary abort: the loading route this open pushed is still on top,
    /// so it is ours to remove.
    func testPopRouteIfStillOwned_RouteStillPending_PopsIt() {
        coordinator.markReadiumPDFPending(forBookId: bookId)
        coordinator.push(.pdf(BookRoute(id: bookId)))

        let popped = service.popRouteIfStillOwned(forBookIdentifier: bookId, on: coordinator)

        XCTAssertTrue(popped)
        XCTAssertEqual(coordinator.path.count, 0, "The reader route this open pushed must be removed")
    }

    /// The regression: patron backed out (pending cleared) and pushed their own
    /// screen. A late abort must leave it alone.
    func testPopRouteIfStillOwned_PatronBackedOutAndPushedTheirOwn_DoesNotPop() {
        coordinator.markReadiumPDFPending(forBookId: bookId)
        coordinator.push(.pdf(BookRoute(id: bookId)))
        // Backing out of the loading view tears the open down…
        coordinator.removeReadiumPDF(forBookId: bookId)
        coordinator.popToRoot(animated: false)
        // …and the patron navigates somewhere else on the same stack.
        coordinator.push(.bookDetail(BookRoute(id: "some-other-book")))

        let popped = service.popRouteIfStillOwned(forBookIdentifier: bookId, on: coordinator)

        XCTAssertFalse(popped)
        XCTAssertEqual(coordinator.path.count, 1,
                       "A late completion must not remove a route the patron pushed after backing out")
    }

    /// A different book's open must not pop this book's route.
    func testPopRouteIfStillOwned_PendingForAnotherBook_DoesNotPop() {
        coordinator.markReadiumPDFPending(forBookId: "a-different-book")
        coordinator.push(.pdf(BookRoute(id: "a-different-book")))

        let popped = service.popRouteIfStillOwned(forBookIdentifier: bookId, on: coordinator)

        XCTAssertFalse(popped)
        XCTAssertEqual(coordinator.path.count, 1)
    }

    /// Pending but nothing on the stack — nothing to pop, and no crash on the
    /// empty-path edge.
    func testPopRouteIfStillOwned_EmptyPath_DoesNotPop() {
        coordinator.markReadiumPDFPending(forBookId: bookId)

        let popped = service.popRouteIfStillOwned(forBookIdentifier: bookId, on: coordinator)

        XCTAssertFalse(popped)
        XCTAssertEqual(coordinator.path.count, 0)
    }

    /// No stack recorded for the open at all (its host was torn down): nothing
    /// to act on, and emphatically not "act on whatever is visible instead".
    func testPopRouteIfStillOwned_NoCoordinator_DoesNothing() {
        XCTAssertFalse(service.popRouteIfStillOwned(forBookIdentifier: bookId, on: nil))
    }

    // MARK: - Superseded-open detection

    /// The generation an open started under is still current: its completions
    /// are the ones that should act.
    func testIsSupersededOpen_GenerationUnchanged_IsNotSuperseded() {
        XCTAssertFalse(service.isSupersededOpen(forBookIdentifier: bookId, generation: 0))
    }

    /// A back-out bumps the generation via teardown, so the completion still in
    /// flight from the previous open must recognise itself as stale — otherwise
    /// its cleanup lands on the open that replaced it.
    func testIsSupersededOpen_AfterTeardown_OldGenerationIsSuperseded() {
        service.releaseReadiumPDF(forBookIdentifier: bookId)

        XCTAssertTrue(service.isSupersededOpen(forBookIdentifier: bookId, generation: 0),
                      "A completion from before the teardown must not act")
        XCTAssertFalse(service.isSupersededOpen(forBookIdentifier: bookId, generation: 1),
                       "The open that replaced it is the current one")
    }

    /// Staleness is per book: tearing down book A must not make book B's
    /// in-flight completion look superseded.
    func testIsSupersededOpen_IsScopedToTheBook() {
        service.releaseReadiumPDF(forBookIdentifier: "another-book")

        XCTAssertFalse(service.isSupersededOpen(forBookIdentifier: bookId, generation: 0),
                       "Another book's teardown must not supersede this book's open")
    }
}
