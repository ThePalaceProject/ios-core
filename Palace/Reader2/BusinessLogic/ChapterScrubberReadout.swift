//
//  ChapterScrubberReadout.swift
//  The Palace Project
//
//  PP-5006: composes what the scrubber says about where a drag would land.
//
//  Two audiences, one source of truth. The visual bubble puts the chapter on
//  its own line above the page/percent detail; VoiceOver gets the same facts as
//  one spoken sentence, composed by `TPPReaderPositionReport` — the same
//  composer the reader's existing "Where am I?" action uses, so a scrubbed
//  position and a queried position are phrased identically.
//
//  Every string here is one the reader already ships. A prototype that invents
//  patron-facing copy commits the product to wording nobody signed off on.
//

import Foundation

enum ChapterScrubberReadout {
    typealias Target = ChapterScrubberModel.Target

    /// The visual bubble. Line one is the chapter, line two the page and
    /// percent. Either line is omitted when the book cannot supply it, and a
    /// book that can supply neither a chapter nor a page still shows a percent.
    static func displayText(for target: Target) -> String {
        var lines: [String] = []

        if let chapter = target.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !chapter.isEmpty {
            lines.append(chapter)
        }

        var detail: [String] = []
        if let page = target.page, target.pageCount > 0 {
            detail.append(String(format: Strings.TPPBaseReaderViewController.pageOf, page) + "\(target.pageCount)")
        }
        detail.append(String(format: Strings.TPPBaseReaderViewController.percentRead, target.percent))
        lines.append(detail.joined(separator: ", "))

        return lines.joined(separator: "\n")
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
