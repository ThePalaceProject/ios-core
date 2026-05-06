//
//  ReadingPositionTests.swift
//  PalaceTests
//
//  Tests for ReadingPosition creation, Codable, and validation.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ReadingPositionTests: XCTestCase {

    // MARK: - EPUB Position

    func testEpubPosition_SetsFormatAndFields() {
        let pos = ReadingPosition.epub(
            bookID: "epub-1",
            chapterIndex: 3,
            chapterProgress: 0.45,
            cfi: "/6/4[chap01]!/4/2",
            deviceID: "test-device"
        )

        XCTAssertEqual(pos.bookID, "epub-1")
        XCTAssertEqual(pos.format, .epub)
        XCTAssertEqual(pos.chapterIndex, 3)
        XCTAssertEqual(pos.chapterProgress, 0.45)
        XCTAssertEqual(pos.cfi, "/6/4[chap01]!/4/2")
        XCTAssertEqual(pos.deviceID, "test-device")
    }

    func testEpubPosition_ProgressClampedAbove1() {
        let pos = ReadingPosition.epub(
            bookID: "epub-1",
            chapterIndex: 0,
            chapterProgress: 1.5,
            deviceID: "test"
        )
        XCTAssertEqual(pos.chapterProgress, 1.0)
    }

    func testEpubPosition_ProgressClampedBelow0() {
        let pos = ReadingPosition.epub(
            bookID: "epub-1",
            chapterIndex: 0,
            chapterProgress: -0.3,
            deviceID: "test"
        )
        XCTAssertEqual(pos.chapterProgress, 0.0)
    }

    func testEpubPosition_ProgressBoundary0() {
        let pos = ReadingPosition.epub(
            bookID: "epub-1",
            chapterIndex: 0,
            chapterProgress: 0.0,
            deviceID: "test"
        )
        XCTAssertEqual(pos.chapterProgress, 0.0)
    }

    func testEpubPosition_ProgressBoundary1() {
        let pos = ReadingPosition.epub(
            bookID: "epub-1",
            chapterIndex: 0,
            chapterProgress: 1.0,
            deviceID: "test"
        )
        XCTAssertEqual(pos.chapterProgress, 1.0)
    }

    // MARK: - Audiobook Position

    func testAudiobookPosition_SetsFormatAndFields() {
        let pos = ReadingPosition.audiobook(
            bookID: "audio-1",
            chapterIndex: 5,
            timeOffset: 123.45,
            deviceID: "test-device"
        )

        XCTAssertEqual(pos.bookID, "audio-1")
        XCTAssertEqual(pos.format, .audiobook)
        XCTAssertEqual(pos.audiobookChapterIndex, 5)
        XCTAssertEqual(pos.audiobookTimeOffset, 123.45)
        XCTAssertEqual(pos.deviceID, "test-device")
    }

    func testAudiobookPosition_NegativeTimeOffset_ClampedToZero() {
        let pos = ReadingPosition.audiobook(
            bookID: "audio-1",
            chapterIndex: 0,
            timeOffset: -10.0,
            deviceID: "test"
        )
        XCTAssertEqual(pos.audiobookTimeOffset, 0.0)
    }

    func testAudiobookPosition_ZeroTimeOffset() {
        let pos = ReadingPosition.audiobook(
            bookID: "audio-1",
            chapterIndex: 0,
            timeOffset: 0.0,
            deviceID: "test"
        )
        XCTAssertEqual(pos.audiobookTimeOffset, 0.0)
    }

    // MARK: - PDF Position

    func testPdfPosition_SetsFormatAndFields() {
        let pos = ReadingPosition.pdf(
            bookID: "pdf-1",
            pageNumber: 42,
            deviceID: "test-device"
        )

        XCTAssertEqual(pos.bookID, "pdf-1")
        XCTAssertEqual(pos.format, .pdf)
        XCTAssertEqual(pos.pdfPageNumber, 42)
        XCTAssertEqual(pos.deviceID, "test-device")
    }

    func testPdfPosition_PageNumberClampedToMinimum1() {
        let pos = ReadingPosition.pdf(
            bookID: "pdf-1",
            pageNumber: 0,
            deviceID: "test"
        )
        XCTAssertEqual(pos.pdfPageNumber, 1)
    }

    func testPdfPosition_NegativePageNumber_ClampedTo1() {
        let pos = ReadingPosition.pdf(
            bookID: "pdf-1",
            pageNumber: -5,
            deviceID: "test"
        )
        XCTAssertEqual(pos.pdfPageNumber, 1)
    }

    // MARK: - Codable Round-Trips

    func testEpubPosition_CodableRoundTrip() throws {
        let original = ReadingPosition.epub(
            bookID: "epub-rt",
            chapterIndex: 2,
            chapterProgress: 0.75,
            cfi: "/6/14",
            overallProgress: 0.5,
            deviceID: "device-1"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReadingPosition.self, from: data)

        XCTAssertEqual(decoded.bookID, original.bookID)
        XCTAssertEqual(decoded.format, .epub)
        XCTAssertEqual(decoded.chapterIndex, 2)
        XCTAssertEqual(decoded.chapterProgress, 0.75)
        XCTAssertEqual(decoded.cfi, "/6/14")
        XCTAssertEqual(decoded.overallProgress, 0.5)
        XCTAssertEqual(decoded.deviceID, "device-1")
    }

    func testAudiobookPosition_CodableRoundTrip() throws {
        let original = ReadingPosition.audiobook(
            bookID: "audio-rt",
            chapterIndex: 3,
            timeOffset: 456.78,
            overallProgress: 0.33,
            deviceID: "device-2"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReadingPosition.self, from: data)

        XCTAssertEqual(decoded.bookID, original.bookID)
        XCTAssertEqual(decoded.format, .audiobook)
        XCTAssertEqual(decoded.audiobookChapterIndex, 3)
        XCTAssertEqual(decoded.audiobookTimeOffset, 456.78)
        XCTAssertEqual(decoded.overallProgress, 0.33)
    }

    func testPdfPosition_CodableRoundTrip() throws {
        let original = ReadingPosition.pdf(
            bookID: "pdf-rt",
            pageNumber: 100,
            overallProgress: 0.8,
            deviceID: "device-3"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReadingPosition.self, from: data)

        XCTAssertEqual(decoded.bookID, original.bookID)
        XCTAssertEqual(decoded.format, .pdf)
        XCTAssertEqual(decoded.pdfPageNumber, 100)
        XCTAssertEqual(decoded.overallProgress, 0.8)
    }

    // MARK: - Equality

    func testEquality_SamePosition() {
        let date = Date()
        let a = ReadingPosition(
            bookID: "b1", format: .epub, timestamp: date, deviceID: "d1",
            chapterIndex: 1, chapterProgress: 0.5
        )
        let b = ReadingPosition(
            bookID: "b1", format: .epub, timestamp: date, deviceID: "d1",
            chapterIndex: 1, chapterProgress: 0.5
        )
        XCTAssertEqual(a, b)
    }

    func testEquality_DifferentChapter_NotEqual() {
        let date = Date()
        let a = ReadingPosition(
            bookID: "b1", format: .epub, timestamp: date, deviceID: "d1",
            chapterIndex: 1, chapterProgress: 0.5
        )
        let b = ReadingPosition(
            bookID: "b1", format: .epub, timestamp: date, deviceID: "d1",
            chapterIndex: 2, chapterProgress: 0.5
        )
        XCTAssertNotEqual(a, b)
    }

    func testEquality_DifferentFormat_NotEqual() {
        let date = Date()
        let a = ReadingPosition(
            bookID: "b1", format: .epub, timestamp: date, deviceID: "d1"
        )
        let b = ReadingPosition(
            bookID: "b1", format: .pdf, timestamp: date, deviceID: "d1"
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Device ID

    func testDeviceID_IsPopulated() {
        let pos = ReadingPosition.epub(
            bookID: "b1",
            chapterIndex: 0,
            chapterProgress: 0.0
        )
        XCTAssertFalse(pos.deviceID.isEmpty)
    }

    // MARK: - Display Description

    func testDisplayDescription_Epub() {
        let pos = ReadingPosition.epub(
            bookID: "b1",
            chapterIndex: 2,
            chapterProgress: 0.65,
            deviceID: "test"
        )
        XCTAssertEqual(pos.displayDescription, "Chapter 3, 65% through")
    }

    func testDisplayDescription_Audiobook() {
        let pos = ReadingPosition.audiobook(
            bookID: "b1",
            chapterIndex: 1,
            timeOffset: 125.0,
            deviceID: "test"
        )
        XCTAssertEqual(pos.displayDescription, "Chapter 2, 2:05")
    }

    func testDisplayDescription_Pdf() {
        let pos = ReadingPosition.pdf(
            bookID: "b1",
            pageNumber: 42,
            deviceID: "test"
        )
        XCTAssertEqual(pos.displayDescription, "Page 42")
    }

    // MARK: - ReadingFormat Codable

    func testReadingFormat_CodableRoundTrip() throws {
        for format in [ReadingFormat.epub, .audiobook, .pdf] {
            let data = try JSONEncoder().encode(format)
            let decoded = try JSONDecoder().decode(ReadingFormat.self, from: data)
            XCTAssertEqual(decoded, format)
        }
    }
}
