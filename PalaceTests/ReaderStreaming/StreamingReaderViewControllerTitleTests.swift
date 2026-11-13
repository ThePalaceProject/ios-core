//
//  StreamingReaderViewControllerTitleTests.swift
//  PalaceTests
//
//  The streaming reader is pushed inside its own `UINavigationController`
//  (see `StreamingReaderView.makeUIViewController`) and that bar carries no
//  other item, so `UIViewController.title` is the only thing naming the
//  screen — both visually and for VoiceOver's screen-change announcement.
//  These tests pin that the name comes from the book being read, on the
//  connected path and on the offline path alike.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class StreamingReaderViewControllerTitleTests: XCTestCase {

    /// Every controller these tests load, released explicitly in `tearDown`.
    ///
    /// `loadViewIfNeeded()` runs `viewDidLoad`, which builds a `WKWebView` — and
    /// a WKWebView is backed by a separate WebContent process, not just memory.
    /// Held as locals the controllers still deallocate, but only when the
    /// enclosing autorelease pool drains, which is after the test method and
    /// potentially after several more have started. Naming them here gives the
    /// release a deterministic point.
    ///
    /// This is hygiene rather than a proven fix. Two full-suite runs of this
    /// branch each masked a different duration-inflated failure —
    /// `AudiobookLoaderTests` at 7.7/18.8/27.7s, then `TPPAlertUtilsTests` at
    /// 3.4s — where both victims pass in under a second everywhere else,
    /// including on this branch. That is the shape of resource pressure rather
    /// than a logic defect, and three extra web content processes are the only
    /// resource this branch adds. Not established: a scoped run of these two
    /// classes together did NOT reproduce it, so if the cause is here it is a
    /// whole-suite effect that a five-test experiment cannot show.
    private var loadedControllers: [StreamingReaderViewController] = []

    override func tearDown() {
        loadedControllers.forEach { $0.viewIfLoaded?.removeFromSuperview() }
        loadedControllers.removeAll()
        super.tearDown()
    }

    /// Builds the controller, loads its view, and registers it for teardown.
    private func makeLoadedController(title: String, connected: Bool) -> StreamingReaderViewController {
        let vc = StreamingReaderViewController(
            viewModel: makeViewModel(title: title, connected: connected)
        )
        loadedControllers.append(vc)
        vc.loadViewIfNeeded()
        return vc
    }

    private func makeViewModel(title: String, connected: Bool) -> StreamingReaderViewModel {
        StreamingReaderViewModel(
            book: TPPBookMocker.mockBook(identifier: "streaming-title-\(title.hashValue)", title: title),
            store: FakeStreamingReaderProgressStore(),
            reachability: FakeReachability(connected: connected)
        )
    }

    func testStreamingReader_afterViewDidLoad_namesTheScreenWithTheBookTitle() {
        let vc = makeLoadedController(title: "The Wind in the Willows", connected: true)

        XCTAssertEqual(
            vc.title, "The Wind in the Willows",
            "The hosting navigation bar has no other item, so this title is the screen's only name."
        )
    }

    /// The offline branch swaps the web view for the "Connection required"
    /// container. The screen still has to say which book it belongs to.
    func testStreamingReader_whenOffline_stillNamesTheScreenWithTheBookTitle() {
        let vc = makeLoadedController(title: "Nona Vincent", connected: false)

        XCTAssertEqual(
            vc.title, "Nona Vincent",
            "The name is taken from the book, not from the loaded state, so the error screen is named too."
        )
    }

    /// Two readers opened in the same session must not share a name — the
    /// title has to track the view model's book rather than any fixed string.
    func testStreamingReader_twoBooks_produceDistinctScreenNames() {
        let first = makeLoadedController(title: "First Title", connected: true)
        let second = makeLoadedController(title: "Second Title", connected: true)

        XCTAssertEqual(first.title, "First Title")
        XCTAssertEqual(second.title, "Second Title")
        XCTAssertNotEqual(first.title, second.title)
    }
}
