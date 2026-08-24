//
//  ChapterScrubberReadoutTests.swift
//  The Palace Project
//
//  PP-5006: behavior spec for what the scrubber says during a drag.
//

import XCTest
@testable import Palace

final class ChapterScrubberReadoutTests: XCTestCase {

    private func target(
        progression: Double = 0.41,
        chapterTitle: String? = "Chapter 7",
        page: Int? = 214,
        pageCount: Int = 512,
        percent: Int = 41
    ) -> ChapterScrubberModel.Target {
        .init(
            progression: progression,
            chapterTitle: chapterTitle,
            page: page,
            pageCount: pageCount,
            percent: percent
        )
    }

    // MARK: - Card rows

    func testChapterLine_IsTheChapterTitle() {
        XCTAssertEqual(ChapterScrubberReadout.chapterLine(for: target()), "Chapter 7")
    }

    func testChapterLine_WithNoChapter_IsNil() {
        XCTAssertNil(ChapterScrubberReadout.chapterLine(for: target(chapterTitle: nil)))
    }

    func testChapterLine_WithABlankChapterTitle_IsNil() {
        // A whitespace-only title would otherwise reserve a card row that
        // renders as an empty gap.
        XCTAssertNil(ChapterScrubberReadout.chapterLine(for: target(chapterTitle: "   ")))
    }

    func testChapterLine_TrimsSurroundingWhitespace() {
        XCTAssertEqual(
            ChapterScrubberReadout.chapterLine(for: target(chapterTitle: "  Chapter 7\n")),
            "Chapter 7"
        )
    }

    func testDetailLine_ReportsPagePositionAndPercent() {
        let detail = ChapterScrubberReadout.detailLine(for: target())
        XCTAssertTrue(detail.contains("214"), detail)
        XCTAssertTrue(detail.contains("512"), detail)
        XCTAssertTrue(detail.contains("41"), detail)
    }

    func testDetailLine_IsOneLine_SoTheCardRowsStayIndependent() {
        // Each card row is its own label; a newline here would put two figures
        // in one row and reintroduce the collision the stacked layout avoids.
        XCTAssertFalse(ChapterScrubberReadout.detailLine(for: target()).contains("\n"))
    }

    func testDetailLine_WithNoPages_StillReportsPercent() {
        let detail = ChapterScrubberReadout.detailLine(
            for: target(chapterTitle: nil, page: nil, pageCount: 0, percent: 41)
        )
        XCTAssertTrue(detail.contains("41"), detail)
        XCTAssertFalse(detail.contains("0"), detail)
    }

    func testDetailLine_IsNeverEmpty() {
        // The card always has something to say, even for a book that reports
        // neither chapters nor pages.
        let detail = ChapterScrubberReadout.detailLine(
            for: target(chapterTitle: nil, page: nil, pageCount: 0, percent: 0)
        )
        XCTAssertFalse(detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Spoken readout

    func testAccessibilityValue_SpeaksChapterPageAndPercent() {
        let spoken = ChapterScrubberReadout.accessibilityValue(for: target())
        XCTAssertTrue(spoken.contains("Chapter 7"), spoken)
        XCTAssertTrue(spoken.contains("214"), spoken)
        XCTAssertTrue(spoken.contains("41"), spoken)
    }

    func testAccessibilityValue_OmitsComponentsTheBookCannotSupply() {
        let spoken = ChapterScrubberReadout.accessibilityValue(
            for: target(chapterTitle: nil, page: nil, pageCount: 0)
        )
        XCTAssertFalse(spoken.contains("Chapter"), spoken)
        XCTAssertFalse(spoken.contains("Page"), spoken)
        XCTAssertTrue(spoken.contains("41"), spoken)
    }

    func testAccessibilityValue_DerivesPercentFromProgressionNotTheDisplayPercent() {
        // The spoken value goes through the reader's existing position
        // composer, which rounds the progression itself. Passing 0.415 must
        // speak 42% even though the visual readout carries 41.
        let spoken = ChapterScrubberReadout.accessibilityValue(
            for: target(progression: 0.415, chapterTitle: nil, page: nil, pageCount: 0, percent: 41)
        )
        XCTAssertTrue(spoken.contains("42"), spoken)
    }
}
