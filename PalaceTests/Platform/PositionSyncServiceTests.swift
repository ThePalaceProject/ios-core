//
//  PositionSyncServiceTests.swift
//  PalaceTests
//
//  Tests for the cross-format position sync service.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

final class PositionSyncServiceTests: XCTestCase {

    private var service: PositionSyncService!
    private var userDefaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "PositionSyncServiceTests")!
        userDefaults.removePersistentDomain(forName: "PositionSyncServiceTests")
        service = PositionSyncService(userDefaults: userDefaults)
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        userDefaults.removePersistentDomain(forName: "PositionSyncServiceTests")
        service = nil
        userDefaults = nil
        super.tearDown()
    }

    // MARK: - Recording

    func testRecordEpubPosition() async {
        let position = ReadingPosition.epub(
            bookID: "book1",
            chapterIndex: 3,
            chapterProgress: 0.5,
            cfi: "/6/14!/4/2",
            deviceID: "device1"
        )

        await service.recordPosition(position)

        let retrieved = await service.latestPosition(forBook: "book1", format: .epub)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.bookID, "book1")
        XCTAssertEqual(retrieved?.chapterIndex, 3)
        XCTAssertEqual(retrieved?.chapterProgress, 0.5)
        XCTAssertEqual(retrieved?.cfi, "/6/14!/4/2")
    }

    func testRecordAudiobookPosition() async {
        let position = ReadingPosition.audiobook(
            bookID: "book1",
            chapterIndex: 2,
            timeOffset: 145.5,
            deviceID: "device1"
        )

        await service.recordPosition(position)

        let retrieved = await service.latestPosition(forBook: "book1", format: .audiobook)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.audiobookChapterIndex, 2)
        XCTAssertEqual(retrieved?.audiobookTimeOffset, 145.5)
    }

    func testRecordPdfPosition() async {
        let position = ReadingPosition.pdf(bookID: "book1", pageNumber: 42, deviceID: "device1")

        await service.recordPosition(position)

        let retrieved = await service.latestPosition(forBook: "book1", format: .pdf)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.pdfPageNumber, 42)
    }

    func testLatestPositionAnyFormat() async {
        let epubPos = ReadingPosition.epub(
            bookID: "book1", chapterIndex: 1, chapterProgress: 0.2, deviceID: "d1"
        )
        await service.recordPosition(epubPos)

        // Record audiobook position after a slight delay to ensure different timestamps
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        let abPos = ReadingPosition.audiobook(
            bookID: "book1", chapterIndex: 5, timeOffset: 300, deviceID: "d1"
        )
        await service.recordPosition(abPos)

        let latest = await service.latestPositionAnyFormat(forBook: "book1")
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.format, .audiobook)
    }

    // MARK: - Sync Offers

    func testSyncOfferWhenOtherFormatIsMoreRecent() async {
        // Record an audiobook position
        let abPos = ReadingPosition.audiobook(
            bookID: "book1", chapterIndex: 5, timeOffset: 300, deviceID: "d1"
        )
        await service.recordPosition(abPos)

        // Set up a mapping
        let mapping = CrossFormatMapping.oneToOne(bookID: "book1", chapterCount: 10)
        await service.setMapping(mapping)

        // Open the EPUB — should get a sync offer
        let offer = await service.checkForSyncOffer(bookID: "book1", openingFormat: .epub)
        XCTAssertNotNil(offer, "Should offer sync when other format has a more recent position")
    }

    func testNoSyncOfferWhenCurrentFormatIsMoreRecent() async {
        // Record audiobook position first
        let abPos = ReadingPosition.audiobook(
            bookID: "book1", chapterIndex: 5, timeOffset: 300, deviceID: "d1"
        )
        await service.recordPosition(abPos)

        try? await Task.sleep(nanoseconds: 10_000_000)

        // Record epub position more recently
        let epubPos = ReadingPosition.epub(
            bookID: "book1", chapterIndex: 7, chapterProgress: 0.8, deviceID: "d1"
        )
        await service.recordPosition(epubPos)

        // Open EPUB — should NOT get a sync offer since it's already the most recent
        let offer = await service.checkForSyncOffer(bookID: "book1", openingFormat: .epub)
        XCTAssertNil(offer, "Should not offer sync when current format is already most recent")
    }

    func testNoSyncOfferForUnknownBook() async {
        let offer = await service.checkForSyncOffer(bookID: "unknown", openingFormat: .epub)
        XCTAssertNil(offer)
    }

    // MARK: - Event Publishing

    func testPositionRecordedEventPublished() async {
        let expectation = XCTestExpectation(description: "Position recorded event")

        service.eventPublisher
            .sink { event in
                if case .positionRecorded(let pos) = event {
                    XCTAssertEqual(pos.bookID, "book1")
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        let position = ReadingPosition.epub(
            bookID: "book1", chapterIndex: 0, chapterProgress: 0, deviceID: "d1"
        )
        await service.recordPosition(position)

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testSyncAvailableEventPublished() async {
        let expectation = XCTestExpectation(description: "Sync available event")

        let abPos = ReadingPosition.audiobook(
            bookID: "book1", chapterIndex: 3, timeOffset: 100, deviceID: "d1"
        )
        await service.recordPosition(abPos)

        let mapping = CrossFormatMapping.oneToOne(bookID: "book1", chapterCount: 10)
        await service.setMapping(mapping)

        service.eventPublisher
            .sink { event in
                if case .syncAvailable = event {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        _ = await service.checkForSyncOffer(bookID: "book1", openingFormat: .epub)

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - Mappings

    func testSetAndRetrieveMapping() async {
        let mapping = CrossFormatMapping.proportional(
            bookID: "book1", epubChapterCount: 20, audiobookChapterCount: 10
        )
        await service.setMapping(mapping)

        let retrieved = await service.mapping(forBook: "book1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.epubChapterCount, 20)
        XCTAssertEqual(retrieved?.audiobookChapterCount, 10)
    }

    // MARK: - Cleanup

    func testClearPositionsForBook() async {
        let position = ReadingPosition.epub(
            bookID: "book1", chapterIndex: 0, chapterProgress: 0, deviceID: "d1"
        )
        await service.recordPosition(position)

        await service.clearPositions(forBook: "book1")

        let retrieved = await service.latestPosition(forBook: "book1", format: .epub)
        XCTAssertNil(retrieved)
    }

    func testClearAll() async {
        let pos1 = ReadingPosition.epub(bookID: "book1", chapterIndex: 0, chapterProgress: 0, deviceID: "d1")
        let pos2 = ReadingPosition.epub(bookID: "book2", chapterIndex: 0, chapterProgress: 0, deviceID: "d1")
        await service.recordPosition(pos1)
        await service.recordPosition(pos2)

        await service.clearAll()

        let r1 = await service.latestPosition(forBook: "book1", format: .epub)
        let r2 = await service.latestPosition(forBook: "book2", format: .epub)
        XCTAssertNil(r1)
        XCTAssertNil(r2)
    }

    // MARK: - Persistence

    func testPersistenceAcrossInstances() async {
        let position = ReadingPosition.epub(
            bookID: "book1", chapterIndex: 5, chapterProgress: 0.75, deviceID: "d1"
        )
        await service.recordPosition(position)

        // Create a new service instance with the same UserDefaults
        let newService = PositionSyncService(userDefaults: userDefaults)
        let retrieved = await newService.latestPosition(forBook: "book1", format: .epub)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.chapterIndex, 5)
        XCTAssertEqual(retrieved?.chapterProgress, 0.75)
    }
}
