//
//  AudiobookLoaderTimeTrackerTests.swift
//  PalaceTests
//
//  PP-5508: the loader gives each audiobook's time tracker the app's one
//  play-time uploader, so every book's entries reach the same queue.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookLoaderTimeTrackerTests: XCTestCase {

    private let trackingURL = URL(string: "https://example.com/track")!

    private func book(timeTrackingURL: URL?) -> TPPBook {
        TPPBook(
            acquisitions: [TPPOPDSAcquisition(
                relation: .generic,
                type: "application/audiobook+json",
                hrefURL: URL(string: "https://test.example.com/book")!,
                indirectAcquisitions: [],
                availability: TPPOPDSAcquisitionAvailabilityUnlimited()
            )],
            authors: [], categoryStrings: [], distributor: "",
            identifier: "tracked-book",
            imageURL: nil, imageThumbnailURL: nil,
            published: Date(), publisher: "", subtitle: "", summary: "", title: "",
            updated: Date(),
            annotationsURL: nil, analyticsURL: nil, alternateURL: nil, relatedWorksURL: nil,
            previewLink: nil, seriesURL: nil, revokeURL: nil, reportURL: nil,
            timeTrackingURL: timeTrackingURL,
            contributors: [:], bookDuration: nil, imageCache: MockImageCache()
        )
    }

    /// Played time must reach the uploader the loader was given, under this
    /// library and book.
    func testMakeTimeTracker_PlayedTime_IsSavedToTheGivenUploader() throws {
        let uploader = MockDataManager()
        let tracker = try XCTUnwrap(AudiobookLoader.makeTimeTracker(
            libraryId: "lib-1", book: book(timeTrackingURL: trackingURL), uploader: uploader
        ))

        tracker.receiveValue(Date())
        tracker.stopAndSave()
        uploader.flush()

        let entries = uploader.savedTimeEntries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.libraryId, "lib-1")
        XCTAssertEqual(entries.first?.bookId, "tracked-book")
        XCTAssertEqual(entries.first?.timeTrackingUrl, trackingURL)
    }

    /// Without a signed-in library there is nobody to report the time to.
    func testMakeTimeTracker_NoLibrary_ReturnsNil() {
        XCTAssertNil(AudiobookLoader.makeTimeTracker(
            libraryId: nil, book: book(timeTrackingURL: trackingURL), uploader: MockDataManager()
        ))
    }

    /// A book the server does not track gets no tracker.
    func testMakeTimeTracker_NoTimeTrackingLink_ReturnsNil() {
        XCTAssertNil(AudiobookLoader.makeTimeTracker(
            libraryId: "lib-1", book: book(timeTrackingURL: nil), uploader: MockDataManager()
        ))
    }
}
