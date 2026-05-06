//
//  CrossFormatMappingTests.swift
//  PalaceTests
//
//  Tests for cross-format chapter mapping and position conversion.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class CrossFormatMappingTests: XCTestCase {

    // MARK: - One-to-One Mapping

    func testOneToOneMappingCreation() {
        let mapping = CrossFormatMapping.oneToOne(bookID: "book1", chapterCount: 10)
        XCTAssertEqual(mapping.chapterMappings.count, 10)
        XCTAssertEqual(mapping.epubChapterCount, 10)
        XCTAssertEqual(mapping.audiobookChapterCount, 10)

        for i in 0..<10 {
            XCTAssertEqual(mapping.chapterMappings[i].epubChapterIndex, i)
            XCTAssertEqual(mapping.chapterMappings[i].audiobookChapterIndex, i)
        }
    }

    func testOneToOneEpubToAudiobook() {
        let mapping = CrossFormatMapping.oneToOne(bookID: "book1", chapterCount: 10)
        let epub = ReadingPosition.epub(bookID: "book1", chapterIndex: 5, chapterProgress: 0.5, deviceID: "d1")

        let result = mapping.toAudiobookPosition(from: epub)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format, .audiobook)
        XCTAssertEqual(result?.audiobookChapterIndex, 5)
    }

    func testOneToOneAudiobookToEpub() {
        let mapping = CrossFormatMapping.oneToOne(bookID: "book1", chapterCount: 10)
        let ab = ReadingPosition.audiobook(bookID: "book1", chapterIndex: 3, timeOffset: 60, deviceID: "d1")

        let result = mapping.toEpubPosition(from: ab)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format, .epub)
        XCTAssertEqual(result?.chapterIndex, 3)
    }

    // MARK: - Proportional Mapping

    func testProportionalMappingCreation() {
        let mapping = CrossFormatMapping.proportional(bookID: "book1", epubChapterCount: 20, audiobookChapterCount: 10)
        XCTAssertEqual(mapping.chapterMappings.count, 20)
        XCTAssertEqual(mapping.epubChapterCount, 20)
        XCTAssertEqual(mapping.audiobookChapterCount, 10)
    }

    func testProportionalEpubToAudiobook() {
        let mapping = CrossFormatMapping.proportional(bookID: "book1", epubChapterCount: 20, audiobookChapterCount: 10)
        // EPUB chapter 10 should map to approximately audiobook chapter 5
        let epub = ReadingPosition.epub(bookID: "book1", chapterIndex: 10, chapterProgress: 0.5, deviceID: "d1")

        let result = mapping.toAudiobookPosition(from: epub)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.audiobookChapterIndex, 5)
    }

    func testProportionalAudiobookToEpub() {
        let mapping = CrossFormatMapping.proportional(bookID: "book1", epubChapterCount: 20, audiobookChapterCount: 10)
        // Audiobook chapter 5 should map to approximately EPUB chapter 10
        let ab = ReadingPosition.audiobook(bookID: "book1", chapterIndex: 5, timeOffset: 0, deviceID: "d1")

        let result = mapping.toEpubPosition(from: ab)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.chapterIndex, 10)
    }

    // MARK: - Edge Cases

    func testMappingWithZeroChapters() {
        let mapping = CrossFormatMapping.proportional(bookID: "book1", epubChapterCount: 0, audiobookChapterCount: 0)
        XCTAssertTrue(mapping.chapterMappings.isEmpty)
    }

    func testMappingWrongFormat() {
        let mapping = CrossFormatMapping.oneToOne(bookID: "book1", chapterCount: 10)
        // Try to convert a PDF position — should return nil
        let pdf = ReadingPosition.pdf(bookID: "book1", pageNumber: 5, deviceID: "d1")
        let result = mapping.toAudiobookPosition(from: pdf)
        XCTAssertNil(result)
    }

    func testMappingWithMissingChapterIndex() {
        let mapping = CrossFormatMapping.oneToOne(bookID: "book1", chapterCount: 10)
        // Create an epub position without chapter index
        var pos = ReadingPosition.epub(bookID: "book1", chapterIndex: 0, chapterProgress: 0, deviceID: "d1")
        pos.chapterIndex = nil

        let result = mapping.toAudiobookPosition(from: pos)
        XCTAssertNil(result)
    }

    func testFirstChapterMapping() {
        let mapping = CrossFormatMapping.oneToOne(bookID: "book1", chapterCount: 10)
        let epub = ReadingPosition.epub(bookID: "book1", chapterIndex: 0, chapterProgress: 0.0, deviceID: "d1")

        let result = mapping.toAudiobookPosition(from: epub)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.audiobookChapterIndex, 0)
    }

    func testLastChapterMapping() {
        let mapping = CrossFormatMapping.oneToOne(bookID: "book1", chapterCount: 10)
        let epub = ReadingPosition.epub(bookID: "book1", chapterIndex: 9, chapterProgress: 1.0, deviceID: "d1")

        let result = mapping.toAudiobookPosition(from: epub)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.audiobookChapterIndex, 9)
    }

    func testChapterBeyondMappingRange() {
        let mapping = CrossFormatMapping.oneToOne(bookID: "book1", chapterCount: 5)
        // Chapter 7 is beyond the mapping range — should use nearest lower
        let epub = ReadingPosition.epub(bookID: "book1", chapterIndex: 7, chapterProgress: 0.5, deviceID: "d1")

        let result = mapping.toAudiobookPosition(from: epub)
        // Should fall back to nearest lower chapter mapping (chapter 4)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.audiobookChapterIndex, 4)
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let mapping = CrossFormatMapping.proportional(bookID: "book1", epubChapterCount: 15, audiobookChapterCount: 8)
        let data = try JSONEncoder().encode(mapping)
        let decoded = try JSONDecoder().decode(CrossFormatMapping.self, from: data)

        XCTAssertEqual(decoded.bookID, mapping.bookID)
        XCTAssertEqual(decoded.epubChapterCount, mapping.epubChapterCount)
        XCTAssertEqual(decoded.audiobookChapterCount, mapping.audiobookChapterCount)
        XCTAssertEqual(decoded.chapterMappings.count, mapping.chapterMappings.count)
    }

    // MARK: - Custom Mapping

    func testCustomChapterMapping() {
        let mappings = [
            ChapterMapping(epubChapterIndex: 0, audiobookChapterIndex: 0),
            ChapterMapping(epubChapterIndex: 1, audiobookChapterIndex: 0), // Two epub chapters map to one AB chapter
            ChapterMapping(epubChapterIndex: 2, audiobookChapterIndex: 1),
            ChapterMapping(epubChapterIndex: 3, audiobookChapterIndex: 2),
        ]
        let mapping = CrossFormatMapping(bookID: "book1", chapterMappings: mappings, epubChapterCount: 4, audiobookChapterCount: 3)

        let epub0 = ReadingPosition.epub(bookID: "book1", chapterIndex: 0, chapterProgress: 0, deviceID: "d1")
        let epub1 = ReadingPosition.epub(bookID: "book1", chapterIndex: 1, chapterProgress: 0, deviceID: "d1")

        let result0 = mapping.toAudiobookPosition(from: epub0)
        let result1 = mapping.toAudiobookPosition(from: epub1)

        XCTAssertEqual(result0?.audiobookChapterIndex, 0)
        XCTAssertEqual(result1?.audiobookChapterIndex, 0) // Both map to AB chapter 0
    }
}
