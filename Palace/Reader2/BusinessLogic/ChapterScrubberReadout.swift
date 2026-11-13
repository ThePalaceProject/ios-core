//
//  ChapterScrubberReadout.swift
//  The Palace Project
//
//  PP-5006: composes what the scrubber says about where a drag would land.
//
//  The drag card stacks a chapter row above a page/percent row (separate rows
//  so each wraps independently at accessibility sizes, PP-5005). VoiceOver gets
//  the same facts from `TPPReaderPositionReport`, the "Where am I?" composer.
//  Only strings the reader already ships are used.
//

import Foundation

enum ChapterScrubberReadout {
    typealias Target = ChapterScrubberModel.Target

    /// The chapter row of the drag card — the book's own words, so nothing
    /// here is Palace copy. Nil when the book has no usable table of contents
    /// or the drag is before the first chapter starts; the card then shows the
    /// detail row alone.
    static func chapterLine(for target: Target) -> String? {
        guard let chapter = target.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !chapter.isEmpty else {
            return nil
        }
        return chapter
    }

    /// The detail row of the drag card: page position and percentage, assembled
    /// from strings the reader already ships. A book with no position list
    /// still reports a percentage, so this is never empty.
    static func detailLine(for target: Target) -> String {
        var parts: [String] = []
        // `page` is non-nil exactly when the book reported positions, so the
        // count is known to be positive here — guarding it again would be an
        // unreachable branch.
        if let page = target.page {
            parts.append(String(format: Strings.TPPBaseReaderViewController.pageOf, page, target.pageCount))
        }
        parts.append(String(format: Strings.TPPBaseReaderViewController.percentRead, target.percent))
        return parts.joined(separator: ", ")
    }

    /// What VoiceOver speaks as the control's value.
    static func accessibilityValue(for target: Target) -> String {
        TPPReaderPositionReport.announcement(
            section: target.chapterTitle,
            pageLabel: target.page.map { "\($0)" },
            totalProgression: target.progression
        )
    }
}
