//
//  BookDetailNavigationTests.swift
//  PalaceTests
//
//  The book detail screen opens a series lane or a related lane's "More" list
//  through an injected `BookDetailNavigating` capability (PP-5548).
//

import SwiftUI
import XCTest
@testable import Palace
import PalaceBookModel
import PalacePreferences

@MainActor
private final class BookDetailNavigatorSpy: BookDetailNavigating {
    private(set) var opened: [BookDetailDestination] = []
    func open(_ destination: BookDetailDestination) { opened.append(destination) }
}

@MainActor
final class BookDetailNavigationTests: XCTestCase {

    private var appContainer: AppContainer!
    private let seriesURL = URL(string: "https://example.com/series/the-series")!
    private let laneURL = URL(string: "https://example.com/groups/by-author")!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() {
        appContainer = nil
        super.tearDown()
    }

    // MARK: - Series link

    /// Tapping the series name opens that series' lane.
    func testShowSeriesLane_BookWithSeriesLink_OpensSeriesLane() {
        let book = makeBook(seriesName: "The Series", seriesURL: seriesURL)
        let spy = BookDetailNavigatorSpy()
        let vm = makeVM(book: book, navigator: spy)

        vm.showSeriesLane()

        XCTAssertEqual(spy.opened, [.seriesLane(seriesURL)])
    }

    /// A series with no lane URL is shown as plain text, so there is nothing to open.
    func testShowSeriesLane_SeriesWithoutURL_OpensNothing() {
        let spy = BookDetailNavigatorSpy()
        let vm = makeVM(book: makeBook(seriesName: "The Series", seriesURL: nil), navigator: spy)

        vm.showSeriesLane()

        XCTAssertEqual(spy.opened, [])
    }

    /// A URL with no series name has no visible row, so there is nothing to open.
    func testShowSeriesLane_URLWithoutSeriesName_OpensNothing() {
        let spy = BookDetailNavigatorSpy()
        let vm = makeVM(book: makeBook(seriesName: nil, seriesURL: seriesURL), navigator: spy)

        vm.showSeriesLane()

        XCTAssertEqual(spy.opened, [])
    }

    // MARK: - Related lane "More"

    /// Tapping "More" on a related lane opens that lane's full list.
    func testShowMoreBooksForLane_LaneWithURL_OpensRelatedLane() {
        let spy = BookDetailNavigatorSpy()
        let vm = makeVM(book: makeBook(seriesName: nil, seriesURL: nil), navigator: spy)
        vm.relatedBooksByLane = [
            "By the author": BookLane(title: "By the author", books: [], subsectionURL: laneURL),
            "Other": BookLane(title: "Other", books: [], subsectionURL: URL(string: "https://example.com/other")!)
        ]

        vm.showMoreBooksForLane(laneTitle: "By the author")

        XCTAssertEqual(spy.opened, [.relatedLane(laneURL)])
    }

    /// An unknown lane, or a lane with no "More" URL, opens nothing.
    func testShowMoreBooksForLane_UnknownLaneOrNoURL_OpensNothing() {
        let spy = BookDetailNavigatorSpy()
        let vm = makeVM(book: makeBook(seriesName: nil, seriesURL: nil), navigator: spy)
        vm.relatedBooksByLane = ["No more": BookLane(title: "No more", books: [], subsectionURL: nil)]

        vm.showMoreBooksForLane(laneTitle: "Missing")
        vm.showMoreBooksForLane(laneTitle: "No more")

        XCTAssertEqual(spy.opened, [])
    }

    // MARK: - Production navigator

    /// Both destinations push the catalog lane route, with no preset title, onto
    /// the visible stack.
    func testCoordinatorNavigator_PushesCatalogLaneRouteOntoVisibleStack() {
        let coordinator = NavigationCoordinator()
        appContainer.navigationCoordinatorHub.register(coordinator, for: .catalog)
        let navigator = CoordinatorBookDetailNavigator(hub: appContainer.navigationCoordinatorHub)

        navigator.open(.seriesLane(seriesURL))
        navigator.open(.relatedLane(laneURL))

        var expected = NavigationPath()
        expected.append(AppRoute.catalogLaneMore(title: "", url: seriesURL))
        expected.append(AppRoute.catalogLaneMore(title: "", url: laneURL))
        XCTAssertEqual(coordinator.path, expected)
    }

    /// The container-built view model, which the screen uses, opens the series
    /// lane on that container's navigation stack.
    func testContainerViewModel_ShowSeriesLane_PushesOntoContainerStack() {
        let coordinator = NavigationCoordinator()
        appContainer.navigationCoordinatorHub.register(coordinator, for: .catalog)
        let vm = BookDetailViewModel(book: makeBook(seriesName: "The Series", seriesURL: seriesURL),
                                     appContainer: appContainer)

        vm.showSeriesLane()

        var expected = NavigationPath()
        expected.append(AppRoute.catalogLaneMore(title: "", url: seriesURL))
        XCTAssertEqual(coordinator.path, expected)
    }

    // MARK: - Helpers

    private func makeBook(seriesName: String?, seriesURL: URL?) -> TPPBook {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        book.seriesName = seriesName
        book.seriesURL = seriesURL
        return book
    }

    private func makeVM(book: TPPBook, navigator: BookDetailNavigating) -> BookDetailViewModel {
        let registry = TPPBookRegistryMock()
        return BookDetailViewModel(
            book: book,
            registry: registry,
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            navigator: navigator
        )
    }
}
