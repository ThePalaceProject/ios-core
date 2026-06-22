//
//  TPPReaderPageListBusinessLogic.swift
//  The Palace Project
//
//  Business logic for navigating a publication's print page-list (EPUB
//  `page-list`). Surfaces the print page boundaries Readium parses into
//  `publication.pageList`, independent of reflowed reading position. Shared by
//  the print-page navigation UI (DAISY nav-110, PP-4529) and the "Where am I?"
//  position report (DAISY nav-310, PP-4527).
//

import Foundation
import ReadiumShared

typealias TPPReaderPageEntry = (label: String, link: Link)

/// Maps a publication's print `page-list` to navigable entries.
///
/// A "print page" is a hard-coded page boundary from the source print edition,
/// exposed by Readium as `publication.pageList` — distinct from reflowed reading
/// position, which changes with font size and screen dimensions.
class TPPReaderPageListBusinessLogic {
    /// Page entries in document order, each a (display label, navigable link).
    /// Entries whose label is empty/whitespace are dropped — a page boundary
    /// with no label is not something a patron can navigate to or cite.
    let pageEntries: [TPPReaderPageEntry]

    private let publication: Publication

    init(publication: Publication) {
        self.publication = publication
        self.pageEntries = publication.pageList.compactMap { link in
            guard let label = link.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else {
                return nil
            }
            return (label: label, link: link)
        }
    }

    /// True when the publication exposes at least one labeled print page.
    /// The page-list UI is hidden entirely when this is false (nav-110 AC: a
    /// title with no page-list shows neither the page list nor "Go to Page").
    var hasPageList: Bool {
        !pageEntries.isEmpty
    }

    var pageCount: Int {
        pageEntries.count
    }

    /// The display label for the page entry at `index`, or nil if out of range.
    func label(at index: Int) -> String? {
        guard pageEntries.indices.contains(index) else {
            return nil
        }
        return pageEntries[index].label
    }

    /// A navigable `Locator` for the page entry at `index`, resolved through the
    /// publication. Returns nil for an out-of-range index or an unresolvable link.
    func locator(at index: Int) async -> Locator? {
        guard pageEntries.indices.contains(index) else {
            return nil
        }
        return await publication.locate(pageEntries[index].link)
    }

    /// Resolve a requested page label to the index of the matching page entry.
    ///
    /// Matching rule (nav-110 AC — labels may be non-numeric, e.g. roman
    /// numerals, and non-contiguous):
    /// 1. An exact (case-insensitive) label match wins, whatever its format.
    /// 2. Otherwise, if the request is numeric, fall back to the nearest
    ///    *preceding* numeric page — the largest numeric label ≤ the request.
    /// 3. Non-numeric requests with no exact match, and numeric requests below
    ///    the lowest numeric page, return nil (not found).
    func indexForPage(labeled request: String) -> Int? {
        let needle = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return nil
        }

        if let exact = pageEntries.firstIndex(where: {
            $0.label.caseInsensitiveCompare(needle) == .orderedSame
        }) {
            return exact
        }

        guard let target = Int(needle) else {
            return nil
        }

        var bestIndex: Int?
        var bestValue = Int.min
        var i = 0
        while i < pageEntries.count {
            if let value = Int(pageEntries[i].label), value <= target, value > bestValue {
                bestValue = value
                bestIndex = i
            }
            i += 1
        }
        return bestIndex
    }
}
