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

    // MARK: - Visual readout

    func testDisplayText_PutsTheChapterOnItsOwnLineAboveTheDetail() {
        let lines = ChapterScrubberReadout.displayText(for: target()).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Chapter 7")
        XCTAssertTrue(lines[1].contains("214"), lines[1])
        XCTAssertTrue(lines[1].contains("512"), lines[1])
        XCTAssertTrue(lines[1].contains("41"), lines[1])
    }

    func testDisplayText_WithNoChapter_ShowsOnlyTheDetailLine() {
        let text = ChapterScrubberReadout.displayText(for: target(chapterTitle: nil))
        XCTAssertFalse(text.contains("\n"), text)
        XCTAssertTrue(text.contains("214"), text)
    }

    func testDisplayText_WithABlankChapterTitle_ShowsOnlyTheDetailLine() {
        let text = ChapterScrubberReadout.displayText(for: target(chapterTitle: "   "))
        XCTAssertFalse(text.contains("\n"), text)
    }

    func testDisplayText_WithNoPages_StillReportsPercent() {
        let text = ChapterScrubberReadout.displayText(
            for: target(chapterTitle: nil, page: nil, pageCount: 0, percent: 41)
        )
        XCTAssertTrue(text.contains("41"), text)
        XCTAssertFalse(text.contains("0"), text)
    }

    func testDisplayText_WithNoChapterAndNoPages_IsNeverEmpty() {
        let text = ChapterScrubberReadout.displayText(
            for: target(chapterTitle: nil, page: nil, pageCount: 0, percent: 0)
        )
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
