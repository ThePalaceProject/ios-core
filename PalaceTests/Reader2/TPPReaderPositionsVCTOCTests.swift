//
//  TPPReaderPositionsVCTOCTests.swift
//  PalaceTests
//
//  PP-5128: the Contents tab rendered blank until the patron switched to
//  Bookmarks and back. `TPPReaderTOCBusinessLogic` loads its elements in an
//  `init`-spawned `Task`; since the class became `@MainActor`, that job cannot
//  run until the main-actor turn that presented the positions VC finishes — and
//  that turn already includes `viewWillAppear`'s `reloadData()`. Nothing
//  reloaded afterwards, so the table kept the zero-row snapshot it took before
//  the TOC existed.
//

import XCTest
@preconcurrency import ReadiumShared
import PalaceBookModel
import PalaceCatalog
@testable import Palace

@MainActor
final class TPPReaderPositionsVCTOCTests: XCTestCase {

    /// Presents the positions VC exactly the way `presentPositionsVC()` does:
    /// the business logic is constructed and the view is loaded + made to
    /// appear inside a SINGLE main-actor turn, so the TOC load job is still
    /// queued when the table takes its first snapshot.
    private func makeAppearedVC(publication: Publication) -> TPPReaderPositionsVC {
        let vc = TPPReaderPositionsVC.newInstance()
        vc.tocBusinessLogic = TPPReaderTOCBusinessLogic(r2Publication: publication,
                                                        currentLocation: nil)
        vc.pageListBusinessLogic = TPPReaderPageListBusinessLogic(publication: publication)
        vc.view.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        vc.loadViewIfNeeded()
        vc.beginAppearanceTransition(true, animated: false)
        vc.endAppearanceTransition()
        vc.view.layoutIfNeeded()
        return vc
    }

    /// Lets the TOC load land and the VC's own reload run, without touching the
    /// segmented control — reproducing "patron just looks at the Contents tab".
    private func settle(_ vc: TPPReaderPositionsVC) async {
        await vc.tocBusinessLogic?.awaitTOCLoad()
        for _ in 0..<5 { await Task.yield() }
        vc.view.layoutIfNeeded()
    }

    func testContentsTab_populates_withoutSwitchingToBookmarksAndBack() async {
        let vc = makeAppearedVC(publication: Self.publicationWithTOC())

        // Precondition the bug depended on: the first snapshot IS empty,
        // because the TOC load has not run yet.
        XCTAssertEqual(vc.tableView.numberOfRows(inSection: 0), 0,
                       "TOC load is asynchronous; the first snapshot is expected to be empty")

        await settle(vc)

        XCTAssertEqual(vc.tableView.numberOfRows(inSection: 0), 5,
                       "Contents must populate on its own once the TOC load lands — PP-5128 required a Bookmarks round-trip to force the reload")
    }

    func testContentsTab_rendersTheTOCTitles_notBookmarkRows() async {
        let vc = makeAppearedVC(publication: Self.publicationWithTOC())
        await settle(vc)

        let cell = vc.tableView(vc.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertTrue(cell is TPPReaderTOCCell,
                      "Contents rows must dequeue the TOC cell")
        XCTAssertEqual(vc.tocBusinessLogic?.titleAndLevel(forItemAt: 0).title, "Introduction")
    }

    /// The reload is deliberately scoped to the Contents tab, so a TOC that
    /// lands while Bookmarks is showing must not redraw Bookmarks — but it must
    /// still be there when the patron comes back. Returning to Contents goes
    /// through `didSelectSegment`, which reloads.
    func testContents_populatesOnReturn_whenTOCLandsWhileBookmarksSelected() async {
        let vc = makeAppearedVC(publication: Self.publicationWithTOC())

        // Patron is on Bookmarks when the load lands.
        vc.segmentedControl.selectedSegmentIndex = 1
        vc.didSelectSegment(vc.segmentedControl)
        await settle(vc)

        // Back to Contents.
        vc.segmentedControl.selectedSegmentIndex = 0
        vc.didSelectSegment(vc.segmentedControl)
        vc.view.layoutIfNeeded()

        XCTAssertEqual(vc.tableView.numberOfRows(inSection: 0), 5,
                       "Scoping the reload to Contents must not lose the TOC when it lands on another tab")
    }

    func testContentsTab_emptyTOC_staysEmpty() async {
        let manifest = Manifest(metadata: Metadata(title: "No TOC"), tableOfContents: [])
        let vc = makeAppearedVC(publication: Publication(manifest: manifest))

        await settle(vc)

        XCTAssertEqual(vc.tableView.numberOfRows(inSection: 0), 0,
                       "A publication with no TOC must not invent rows")
    }

    /// Pins the Contents-only scoping of the reload.
    ///
    /// The bookmark cell renders its chapter name as
    /// `tocBusinessLogic?.title(for: bookmark.href) ?? bookmark.chapter`, so a
    /// reload that fires while Bookmarks is showing swaps a VISIBLE label from
    /// the stored chapter to a TOC-resolved one. Asserts the rendered cell, not
    /// the data source: calling the data-source method re-renders on demand and
    /// would pass whether or not the guard exists.
    ///
    /// Drop `currentTab == .toc` from `reloadWhenTOCLoadCompletes()` and this
    /// test fails; that is the whole point of it.
    func testBookmarksTab_visibleLabelSurvives_whenTOCLandsWhileBookmarksSelected() async throws {
        let publication = Self.publicationWithTOC()   // "/chapter1.xhtml" is titled "Introduction"
        let vc = TPPReaderPositionsVC.newInstance()
        vc.tocBusinessLogic = TPPReaderTOCBusinessLogic(r2Publication: publication, currentLocation: nil)
        vc.pageListBusinessLogic = TPPReaderPageListBusinessLogic(publication: publication)

        let bookmarks = Self.makeBookmarksLogic(publication: publication)
        // Stored chapter deliberately differs from the TOC title for the same href.
        bookmarks.bookmarks = [Self.bookmark(href: "/chapter1.xhtml", chapter: "Stored Chapter Name")]
        vc.bookmarksBusinessLogic = bookmarks

        vc.view.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        vc.loadViewIfNeeded()
        vc.beginAppearanceTransition(true, animated: false)
        vc.endAppearanceTransition()

        // Patron is looking at Bookmarks when the TOC load lands.
        vc.segmentedControl.selectedSegmentIndex = 1
        vc.didSelectSegment(vc.segmentedControl)
        vc.view.layoutIfNeeded()

        let path = IndexPath(row: 0, section: 0)
        let before = (vc.tableView.cellForRow(at: path) as? TPPReaderBookmarkCell)?.chapterLabel.text
        XCTAssertEqual(before, "Stored Chapter Name", "precondition: the row renders the stored chapter")

        await settle(vc)

        let after = (vc.tableView.cellForRow(at: path) as? TPPReaderBookmarkCell)?.chapterLabel.text
        XCTAssertEqual(after, "Stored Chapter Name",
                       "the TOC landing must not rewrite a visible bookmark label — title(for:) would resolve this href to \"Introduction\"")
    }

    // MARK: - Fixture

    private static func makeBookmarksLogic(publication: Publication) -> TPPReaderBookmarksBusinessLogic {
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: "https://test.example.com/book")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = TPPBook(
            acquisitions: [acquisition], authors: [], categoryStrings: [], distributor: "",
            identifier: "pp5128-toc-book", imageURL: nil, imageThumbnailURL: nil,
            published: Date(), publisher: "", subtitle: "", summary: "", title: "Test Book",
            updated: Date(), annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
            relatedWorksURL: nil, previewLink: nil, seriesURL: nil, revokeURL: nil,
            reportURL: nil, timeTrackingURL: nil, contributors: [:], bookDuration: nil,
            imageCache: MockImageCache()
        )
        return TPPReaderBookmarksBusinessLogic(
            book: book,
            r2Publication: publication,
            drmDeviceID: "test-device-id",
            bookRegistryProvider: TPPBookRegistryMock(),
            currentLibraryAccountProvider: TPPLibraryAccountMock()
        )
    }

    private static func bookmark(href: String, chapter: String) -> TPPReadiumBookmark {
        TPPReadiumBookmark(
            annotationId: "annotation-\(UUID().uuidString)",
            href: href,
            chapter: chapter,
            page: nil,
            location: nil,
            progressWithinChapter: 0.5,
            progressWithinBook: 0.1,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: 0,
            time: nil,
            device: nil
        )!
    }


    /// Three top-level entries, one with two children → 5 flattened rows.
    private static func publicationWithTOC() -> Publication {
        let toc = [
            Link(href: "/chapter1.xhtml", mediaType: .xhtml, title: "Introduction"),
            Link(href: "/chapter2.xhtml", mediaType: .xhtml, title: "Part 1", children: [
                Link(href: "/chapter2.xhtml#s1", mediaType: .xhtml, title: "Section 1.1"),
                Link(href: "/chapter2.xhtml#s2", mediaType: .xhtml, title: "Section 1.2")
            ]),
            Link(href: "/chapter3.xhtml", mediaType: .xhtml, title: "Conclusion")
        ]
        let manifest = Manifest(
            metadata: Metadata(title: "Test Book With TOC", languages: ["en"]),
            readingOrder: [
                Link(href: "/chapter1.xhtml", mediaType: .xhtml),
                Link(href: "/chapter2.xhtml", mediaType: .xhtml),
                Link(href: "/chapter3.xhtml", mediaType: .xhtml)
            ],
            tableOfContents: toc
        )
        return Publication(manifest: manifest)
    }
}
