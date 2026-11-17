//
//  ChapterScrubberModel.swift
//  The Palace Project
//
//  PP-5006: the pure position model behind the EPUB chapter scrubber.
//
//  The scrubber value is a `totalProgression` in `0...1`, labelled with the
//  chapter it falls inside, so it still works when the TOC is missing. No
//  Readium or UIKit: data is precomputed into sorted arrays so a drag update is
//  a binary search with no `await`. `ChapterScrubberModel+Publication.swift`
//  builds one from a `Publication`.
//

import Foundation

struct ChapterScrubberModel: Equatable, Sendable {

    /// A table-of-contents entry reduced to the one fact the scrubber needs:
    /// where in the whole book it begins.
    struct Chapter: Equatable, Sendable {
        let title: String
        /// Where this chapter begins, as a `totalProgression` in `0...1`.
        let startProgression: Double

        init(title: String, startProgression: Double) {
            self.title = title
            self.startProgression = startProgression
        }
    }

    /// Where a drag would land, described the way the readout says it.
    /// Every component except `progression` and `percent` is optional because a
    /// real book may lack a table of contents, a position list, or both.
    struct Target: Equatable, Sendable {
        /// The `totalProgression` to navigate to on release. Always finite and
        /// within `0...1`.
        let progression: Double
        /// The chapter the target falls inside, or nil before the first
        /// chapter start / when the book has no usable table of contents.
        let chapterTitle: String?
        /// 1-based page (Readium "position") containing the target, or nil
        /// when the book reports no positions.
        let page: Int?
        /// Total pages in the book; 0 when unknown.
        let pageCount: Int
        /// Progress through the whole book, `0...100`.
        let percent: Int
    }

    /// Chapter starts, ascending, de-duplicated, titles non-blank.
    private let chapters: [Chapter]
    /// Every position's `totalProgression`, ascending.
    private let positionProgressions: [Double]

    /// How far a VoiceOver increment moves on a book with no chapter structure.
    private static let chapterlessStep = 0.05

    init(chapters: [Chapter], positionProgressions: [Double]) {
        // Normalize once so read paths can assume sorted, in-range data: TOC
        // order is not guaranteed to be reading order, and a malformed entry
        // can resolve outside 0...1.
        var seenStarts = Set<Double>()
        self.chapters = chapters
            .compactMap { chapter -> Chapter? in
                let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return Chapter(title: title, startProgression: Self.clamp(chapter.startProgression))
            }
            .sorted { $0.startProgression < $1.startProgression }
            .filter { seenStarts.insert($0.startProgression).inserted }

        self.positionProgressions = positionProgressions.map(Self.clamp).sorted()
    }

    // MARK: - Shape of the book

    /// The chapter boundaries, as fractions of the book — the tick marks drawn
    /// on the track.
    var chapterMarks: [Double] { chapters.map(\.startProgression) }

    /// Whether the book has a table of contents the scrubber can label with.
    var hasChapterStructure: Bool { !chapters.isEmpty }

    /// Whether there is anywhere to scrub TO. A book with no chapters and at
    /// most one position cannot be navigated by dragging, so the caller hides
    /// the control rather than offering a track that does nothing.
    var isUsable: Bool { hasChapterStructure || positionProgressions.count > 1 }

    // MARK: - Reading the drag

    /// Resolve a drag position to the place it would land. Pure and
    /// synchronous — safe to call on every touch-moved event.
    func target(atFraction fraction: Double) -> Target {
        let progression = Self.clamp(fraction)

        return Target(
            progression: progression,
            chapterTitle: Self.lastIndex(in: chapterMarks, atOrBelow: progression)
                .map { chapters[$0].title },
            page: Self.lastIndex(in: positionProgressions, atOrBelow: progression)
                .map { $0 + 1 }
                ?? (positionProgressions.isEmpty ? nil : 1),
            pageCount: positionProgressions.count,
            percent: Int((progression * 100).rounded())
        )
    }

    /// The next scrub position in the given direction — a chapter boundary when
    /// the book has chapters, a fixed increment when it does not. Backs
    /// VoiceOver's increment/decrement so a non-visual patron moves by chapter
    /// rather than by pixel.
    func step(from fraction: Double, forward: Bool) -> Double {
        let current = Self.clamp(fraction)

        guard hasChapterStructure else {
            return Self.clamp(current + (forward ? Self.chapterlessStep : -Self.chapterlessStep))
        }

        if forward {
            // Strictly greater, so a step off a boundary always moves.
            return chapterMarks.first { $0 > current } ?? 1.0
        } else {
            return chapterMarks.last { $0 < current } ?? 0.0
        }
    }

    // MARK: - Helpers

    private static func clamp(_ value: Double) -> Double {
        // NaN fails every comparison, so it has to be answered explicitly —
        // a zero-width track divides by zero in the caller and would otherwise
        // hand a NaN progression straight to `go(to:)`.
        guard !value.isNaN else { return 0.0 }
        return min(max(value, 0.0), 1.0)
    }

    /// Index of the last element `<= value` in an ascending array, or nil when
    /// every element is greater. Binary search: a several-hundred-page book has
    /// thousands of positions and this runs on every touch-moved event.
    private static func lastIndex(in sorted: [Double], atOrBelow value: Double) -> Int? {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = low + (high - low) / 2
            if sorted[mid] <= value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? low - 1 : nil
    }
}
