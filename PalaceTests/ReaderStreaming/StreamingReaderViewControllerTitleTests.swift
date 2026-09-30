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

    private func makeViewModel(title: String, connected: Bool) -> StreamingReaderViewModel {
        StreamingReaderViewModel(
            book: TPPBookMocker.mockBook(identifier: "streaming-title-\(title.hashValue)", title: title),
            store: FakeStreamingReaderProgressStore(),
            reachability: FakeReachability(connected: connected)
        )
    }

    func testStreamingReader_afterViewDidLoad_namesTheScreenWithTheBookTitle() {
        let vc = StreamingReaderViewController(
            viewModel: makeViewModel(title: "The Wind in the Willows", connected: true)
        )

        vc.loadViewIfNeeded()

        XCTAssertEqual(
            vc.title, "The Wind in the Willows",
            "The hosting navigation bar has no other item, so this title is the screen's only name."
        )
    }

    /// The offline branch swaps the web view for the "Connection required"
    /// container. The screen still has to say which book it belongs to.
    func testStreamingReader_whenOffline_stillNamesTheScreenWithTheBookTitle() {
        let vc = StreamingReaderViewController(
            viewModel: makeViewModel(title: "Nona Vincent", connected: false)
        )

        vc.loadViewIfNeeded()

        XCTAssertEqual(
            vc.title, "Nona Vincent",
            "The name is taken from the book, not from the loaded state, so the error screen is named too."
        )
    }

    /// Two readers opened in the same session must not share a name — the
    /// title has to track the view model's book rather than any fixed string.
    func testStreamingReader_twoBooks_produceDistinctScreenNames() {
        let first = StreamingReaderViewController(
            viewModel: makeViewModel(title: "First Title", connected: true)
        )
        let second = StreamingReaderViewController(
            viewModel: makeViewModel(title: "Second Title", connected: true)
        )

        first.loadViewIfNeeded()
        second.loadViewIfNeeded()

        XCTAssertEqual(first.title, "First Title")
        XCTAssertEqual(second.title, "Second Title")
        XCTAssertNotEqual(first.title, second.title)
    }
}
