//
//  ChapterScrubberModelTests.swift
//  The Palace Project
//
//  PP-5006: behavior spec for the EPUB chapter scrubber's pure position model.
//

import XCTest
@testable import Palace

final class ChapterScrubberModelTests: XCTestCase {

    // MARK: - Fixtures

    /// Six chapters over a 10-position book, chapter starts on position
    /// boundaries. Deliberately NOT evenly spaced so an off-by-one in the
    /// boundary search moves the answer.
    private func makeModel() -> ChapterScrubberModel {
        ChapterScrubberModel(
            chapters: [
                .init(title: "Cover", startProgression: 0.0),
                .init(title: "Chapter 1", startProgression: 0.1),
                .init(title: "Chapter 2", startProgression: 0.4),
                .init(title: "Chapter 3", startProgression: 0.5),
                .init(title: "Chapter 4", startProgression: 0.9)
            ],
            positionProgressions: stride(from: 0.0, to: 1.0, by: 0.1).map { $0 }
        )
    }

    // MARK: - Chapter resolution

    func testTarget_MidChapter_NamesTheEnclosingChapter() {
        let target = makeModel().target(atFraction: 0.45)
        XCTAssertEqual(target.chapterTitle, "Chapter 2")
    }

    func testTarget_ExactlyOnAChapterStart_NamesThatChapterNotThePrevious() {
        // A boundary is INSIDE the chapter it starts. `<` instead of `<=` in the
        // search would answer "Chapter 1" here.
        let target = makeModel().target(atFraction: 0.4)
        XCTAssertEqual(target.chapterTitle, "Chapter 2")
    }

    func testTarget_JustBeforeAChapterStart_NamesThePreviousChapter() {
        let target = makeModel().target(atFraction: 0.399)
        XCTAssertEqual(target.chapterTitle, "Chapter 1")
    }

    func testTarget_PastTheLastChapterStart_NamesTheLastChapter() {
        let target = makeModel().target(atFraction: 1.0)
        XCTAssertEqual(target.chapterTitle, "Chapter 4")
    }

    func testTarget_BeforeTheFirstChapterStart_HasNoChapterTitle() {
        // A book whose first TOC entry starts partway in: dragging into the
        // front matter must not mislabel it as that chapter.
        let model = ChapterScrubberModel(
            chapters: [.init(title: "Chapter 1", startProgression: 0.25)],
            positionProgressions: [0.0, 0.5, 1.0]
        )
        XCTAssertNil(model.target(atFraction: 0.1).chapterTitle)
    }

    // MARK: - Page resolution

    func testTarget_ReportsThePageContainingTheFraction() {
        // positions at 0.0,0.1,...,0.9 → 0.45 sits in the 5th position.
        let target = makeModel().target(atFraction: 0.45)
        XCTAssertEqual(target.page, 5)
        XCTAssertEqual(target.pageCount, 10)
    }

    func testTarget_ExactlyOnAPositionBoundary_ReportsThatPageNotThePrevious() {
        let target = makeModel().target(atFraction: 0.5)
        XCTAssertEqual(target.page, 6)
    }

    func testTarget_AtTheEndOfTheBook_ReportsTheLastPage() {
        let target = makeModel().target(atFraction: 1.0)
        XCTAssertEqual(target.page, 10)
    }

    func testTarget_WhenPositionsAreUnavailable_ReportsNoPage() {
        let model = ChapterScrubberModel(
            chapters: [.init(title: "Chapter 1", startProgression: 0.0)],
            positionProgressions: []
        )
        let target = model.target(atFraction: 0.5)
        XCTAssertNil(target.page)
        XCTAssertEqual(target.pageCount, 0)
    }

    func testTarget_ReportsAPageIfAndOnlyIfTheBookReportsPages() {
        // `ChapterScrubberReadout` relies on this: it prints `page of pageCount`
        // whenever `page` is non-nil, without re-checking the count. If the two
        // could ever disagree the readout would say "Page 3 of 0".
        for positions in [[], [0.0], [0.0, 0.5], [0.0, 0.25, 0.5, 0.75]] as [[Double]] {
            let model = ChapterScrubberModel(chapters: [], positionProgressions: positions)
            for fraction in [0.0, 0.3, 0.5, 0.99, 1.0] {
                let target = model.target(atFraction: fraction)
                XCTAssertEqual(
                    target.page != nil,
                    target.pageCount > 0,
                    "page/pageCount disagree at \(fraction) with \(positions.count) positions"
                )
            }
        }
    }

    // MARK: - Percent

    func testTarget_RoundsPercentToTheNearestWholeNumber() {
        XCTAssertEqual(makeModel().target(atFraction: 0.456).percent, 46)
        XCTAssertEqual(makeModel().target(atFraction: 0.454).percent, 45)
    }

    // MARK: - Out-of-range input

    func testTarget_ClampsFractionsBelowZero() {
        let target = makeModel().target(atFraction: -0.5)
        XCTAssertEqual(target.progression, 0.0)
        XCTAssertEqual(target.percent, 0)
        XCTAssertEqual(target.page, 1)
    }

    func testTarget_ClampsFractionsAboveOne() {
        let target = makeModel().target(atFraction: 4.2)
        XCTAssertEqual(target.progression, 1.0)
        XCTAssertEqual(target.percent, 100)
    }

    func testTarget_ClampsNonFiniteFractionsToTheStartOfTheBook() {
        // A zero-width track divides by zero in the caller; the model must not
        // propagate NaN into a `go(to:)` progression.
        XCTAssertEqual(makeModel().target(atFraction: .nan).progression, 0.0)
        XCTAssertEqual(makeModel().target(atFraction: .infinity).progression, 1.0)
        XCTAssertEqual(makeModel().target(atFraction: -.infinity).progression, 0.0)
    }

    // MARK: - Normalization at construction

    func testInit_SortsChaptersThatArriveOutOfOrder() {
        let model = ChapterScrubberModel(
            chapters: [
                .init(title: "Later", startProgression: 0.8),
                .init(title: "Earlier", startProgression: 0.2)
            ],
            positionProgressions: [0.0, 1.0]
        )
        XCTAssertEqual(model.target(atFraction: 0.5).chapterTitle, "Earlier")
        XCTAssertEqual(model.chapterMarks, [0.2, 0.8])
    }

    func testInit_DropsChaptersWithNoUsableTitle() {
        let model = ChapterScrubberModel(
            chapters: [
                .init(title: "Real", startProgression: 0.0),
                .init(title: "   ", startProgression: 0.5)
            ],
            positionProgressions: [0.0, 1.0]
        )
        XCTAssertEqual(model.chapterMarks, [0.0])
        XCTAssertEqual(model.target(atFraction: 0.6).chapterTitle, "Real")
    }

    func testInit_ClampsOutOfRangeChapterStarts() {
        let model = ChapterScrubberModel(
            chapters: [.init(title: "Bad", startProgression: 1.7)],
            positionProgressions: [0.0]
        )
        XCTAssertEqual(model.chapterMarks, [1.0])
    }

    func testInit_CollapsesChaptersThatShareAStartProgression() {
        // Several TOC entries pointing at fragments of ONE spine resource all
        // resolve to that resource's start. Keep the first so the track doesn't
        // stack invisible ticks and stepping doesn't stall.
        let model = ChapterScrubberModel(
            chapters: [
                .init(title: "Part One", startProgression: 0.5),
                .init(title: "Part One, Section A", startProgression: 0.5),
                .init(title: "Part One, Section B", startProgression: 0.5)
            ],
            positionProgressions: [0.0, 1.0]
        )
        XCTAssertEqual(model.chapterMarks, [0.5])
        XCTAssertEqual(model.target(atFraction: 0.7).chapterTitle, "Part One")
    }

    func testInit_SortsPositionsThatArriveOutOfOrder() {
        let model = ChapterScrubberModel(
            chapters: [],
            positionProgressions: [0.6, 0.0, 0.3]
        )
        XCTAssertEqual(model.target(atFraction: 0.35).page, 2)
    }

    // MARK: - Books with no usable chapter structure

    func testTarget_WithNoChapters_StillReportsPageAndPercent() {
        let model = ChapterScrubberModel(
            chapters: [],
            positionProgressions: [0.0, 0.25, 0.5, 0.75]
        )
        let target = model.target(atFraction: 0.6)
        XCTAssertNil(target.chapterTitle)
        XCTAssertEqual(target.page, 3)
        XCTAssertEqual(target.percent, 60)
    }

    func testHasChapterStructure_IsFalseWhenTheBookHasNoUsableTOC() {
        XCTAssertFalse(ChapterScrubberModel(chapters: [], positionProgressions: [0.0]).hasChapterStructure)
        XCTAssertTrue(makeModel().hasChapterStructure)
    }

    func testIsUsable_IsFalseWhenTheBookHasNeitherChaptersNorPositions() {
        // Nothing to scrub through: the caller hides the control rather than
        // showing a track that cannot move.
        XCTAssertFalse(ChapterScrubberModel(chapters: [], positionProgressions: []).isUsable)
        XCTAssertTrue(ChapterScrubberModel(chapters: [], positionProgressions: [0.0, 1.0]).isUsable)
    }

    func testIsUsable_IsFalseWhenTheBookIsASinglePosition() {
        // A one-position book cannot be scrubbed anywhere.
        XCTAssertFalse(ChapterScrubberModel(chapters: [], positionProgressions: [0.0]).isUsable)
    }

    // MARK: - Long books
    //
    // A several-hundred-page novel is thousands of Readium positions. The drag
    // path answers every touch-moved event from this model, so what matters is
    // that it stays CORRECT and finite at that size — an O(n) scan or an
    // off-by-one in the binary search shows up here as a non-monotonic sweep,
    // not as a stopwatch reading. The timing variant is env-gated below because
    // a wall-clock assertion under parallel test load measures the machine.

    /// ~5,000 positions and 400 chapters — the shape of a long novel.
    private func makeLongBookModel() -> ChapterScrubberModel {
        let positionCount = 5_000
        let chapterCount = 400
        return ChapterScrubberModel(
            chapters: (0..<chapterCount).map {
                .init(title: "Chapter \($0 + 1)", startProgression: Double($0) / Double(chapterCount))
            },
            positionProgressions: (0..<positionCount).map { Double($0) / Double(positionCount) }
        )
    }

    func testTarget_OnALongBook_StaysMonotonicAcrossAFullDrag() {
        // Sweep the whole track the way a finger does. Page and percent must
        // never go backwards while the fraction goes forwards.
        let model = makeLongBookModel()
        var lastPage = 0
        var lastPercent = 0

        for step in 0...1_000 {
            let target = model.target(atFraction: Double(step) / 1_000)
            let page = try! XCTUnwrap(target.page)
            XCTAssertGreaterThanOrEqual(page, lastPage, "page went backwards at step \(step)")
            XCTAssertGreaterThanOrEqual(target.percent, lastPercent, "percent went backwards at step \(step)")
            lastPage = page
            lastPercent = target.percent
        }

        XCTAssertEqual(lastPage, 5_000)
        XCTAssertEqual(lastPercent, 100)
    }

    func testTarget_OnALongBook_ResolvesTheExactPageAndChapter() {
        // Binary search over 5,000 entries: an off-by-one is invisible on the
        // small fixtures above and obvious here.
        let model = makeLongBookModel()

        let target = model.target(atFraction: 0.5)
        XCTAssertEqual(target.page, 2_501)
        XCTAssertEqual(target.pageCount, 5_000)
        XCTAssertEqual(target.chapterTitle, "Chapter 201")

        // One position before the halfway mark.
        XCTAssertEqual(model.target(atFraction: 0.5 - 1.0 / 5_000).page, 2_500)
    }

    func testStep_OnALongBook_AdvancesOneChapterAtATime() {
        let model = makeLongBookModel()
        let start = 0.5
        let next = model.step(from: start, forward: true)
        XCTAssertEqual(next, 0.5025, accuracy: 1e-9)
        XCTAssertEqual(model.target(atFraction: next).chapterTitle, "Chapter 202")
    }

    /// Guards the ALGORITHM, not the machine. A drag update is two binary
    /// searches over ~5,000 entries — roughly a microsecond. The ceiling below
    /// is three orders of magnitude above that, so ordinary test-host load
    /// cannot flip it; only a regression to a linear scan (or an accidental
    /// `await` on the drag path) would. The measured cost is printed so a
    /// reviewer can see the real headroom rather than infer it.
    func testTarget_OnALongBook_CostsFarLessThanAFrame() {
        let model = makeLongBookModel()
        let updates = 1_000
        let started = Date()
        for step in 0..<updates {
            _ = model.target(atFraction: Double(step) / Double(updates))
        }
        let perUpdate = Date().timeIntervalSince(started) / Double(updates)

        print("[PP-5006] chapter-scrubber drag update: \(perUpdate * 1_000_000) µs over 5,000 positions")

        // One 60fps frame is 16,667 µs. 1,000 µs still leaves 16x headroom and
        // is ~1000x the expected cost.
        XCTAssertLessThan(perUpdate, 0.001, "per-update cost \(perUpdate)s suggests the drag path is no longer O(log n)")
    }

    // MARK: - Chapter stepping (VoiceOver increment / decrement)

    func testStep_Forward_LandsOnTheNextChapterStart() {
        XCTAssertEqual(makeModel().step(from: 0.45, forward: true), 0.5)
    }

    func testStep_Backward_LandsOnThePreviousChapterStart() {
        XCTAssertEqual(makeModel().step(from: 0.45, forward: false), 0.4)
    }

    func testStep_ForwardFromExactlyOnAChapterStart_MovesToTheNextChapter() {
        // Otherwise VoiceOver increment wedges on the current boundary forever.
        XCTAssertEqual(makeModel().step(from: 0.4, forward: true), 0.5)
    }

    func testStep_BackwardFromExactlyOnAChapterStart_MovesToThePriorChapter() {
        // Otherwise VoiceOver decrement wedges on the current boundary forever.
        XCTAssertEqual(makeModel().step(from: 0.4, forward: false), 0.1)
    }

    func testStep_ForwardFromTheLastChapter_GoesToTheEndOfTheBook() {
        XCTAssertEqual(makeModel().step(from: 0.95, forward: true), 1.0)
    }

    func testStep_BackwardFromTheFirstChapter_GoesToTheStartOfTheBook() {
        XCTAssertEqual(makeModel().step(from: 0.05, forward: false), 0.0)
    }

    func testStep_WithNoChapters_MovesByAFixedIncrement() {
        let model = ChapterScrubberModel(chapters: [], positionProgressions: [0.0, 1.0])
        XCTAssertEqual(model.step(from: 0.5, forward: true), 0.55, accuracy: 0.0001)
        XCTAssertEqual(model.step(from: 0.5, forward: false), 0.45, accuracy: 0.0001)
    }

    func testStep_WithNoChapters_ClampsAtTheEndsOfTheBook() {
        let model = ChapterScrubberModel(chapters: [], positionProgressions: [0.0, 1.0])
        XCTAssertEqual(model.step(from: 0.98, forward: true), 1.0)
        XCTAssertEqual(model.step(from: 0.02, forward: false), 0.0)
    }
}

// MARK: - TOC → chapter-start resolution

/// `publication.locate(_ link:)` gives a table-of-contents entry no
/// `totalProgression`, so the scrubber derives each chapter's start from the
/// position list instead. These cover that derivation.
final class ChapterScrubberTOCResolutionTests: XCTestCase {

    func testChapters_TakeTheStartOfTheResourceTheEntryPointsInto() {
        let chapters = ChapterScrubberModel.chapters(
            for: [
                .init(title: "One", readingOrderIndex: 0),
                .init(title: "Two", readingOrderIndex: 2)
            ],
            firstProgressionByResource: [0.0, 0.3, 0.7]
        )
        XCTAssertEqual(chapters.map(\.title), ["One", "Two"])
        XCTAssertEqual(chapters.map(\.startProgression), [0.0, 0.7])
    }

    func testChapters_DropsAnEntryPointingPastTheEndOfTheReadingOrder() {
        let chapters = ChapterScrubberModel.chapters(
            for: [
                .init(title: "Real", readingOrderIndex: 0),
                .init(title: "Dangling", readingOrderIndex: 9)
            ],
            firstProgressionByResource: [0.0, 0.5]
        )
        XCTAssertEqual(chapters.map(\.title), ["Real"])
    }

    func testChapters_DropsAnEntryWhoseResourceReportsNoPositions() {
        let chapters = ChapterScrubberModel.chapters(
            for: [
                .init(title: "Empty", readingOrderIndex: 0),
                .init(title: "Real", readingOrderIndex: 1)
            ],
            firstProgressionByResource: [nil, 0.5]
        )
        XCTAssertEqual(chapters.map(\.title), ["Real"])
        XCTAssertEqual(chapters.map(\.startProgression), [0.5])
    }

    func testChapters_WithNoEntries_YieldsNoChapters() {
        XCTAssertTrue(
            ChapterScrubberModel.chapters(for: [], firstProgressionByResource: [0.0, 0.5]).isEmpty
        )
    }

    func testChapters_KeepsSeveralEntriesSharingOneResource_SoInitCanCollapseThem() {
        // Sub-entries of one XHTML file all resolve to that file's start. The
        // resolver keeps them; `init` is what de-duplicates.
        let chapters = ChapterScrubberModel.chapters(
            for: [
                .init(title: "Part One", readingOrderIndex: 1),
                .init(title: "Section A", readingOrderIndex: 1)
            ],
            firstProgressionByResource: [0.0, 0.5]
        )
        XCTAssertEqual(chapters.count, 2)

        let model = ChapterScrubberModel(chapters: chapters, positionProgressions: [0.0, 1.0])
        XCTAssertEqual(model.chapterMarks, [0.5])
    }
}
