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

    // MARK: - Current position (DAISY nav-310, PP-4527)

    /// The print page label for the patron's current reading position, or nil.
    ///
    /// Resolves each print-page boundary to its book progression and picks the
    /// nearest **preceding** boundary (the page whose progression is the largest
    /// value ≤ the locator's `totalProgression`), then returns its display label
    /// via `label(at:)`. Returns nil when the locator has no `totalProgression`,
    /// the publication has no page-list, or no boundary precedes the position —
    /// the absence of a page number is not an error (nav-310 AC).
    func currentPageLabel(for locator: Locator) async -> String? {
        guard let current = locator.locations.totalProgression else {
            return nil
        }

        // Index-free iteration: the per-entry resolution loop has no observable
        // arithmetic to mutate (the orderable logic lives in nearestPrecedingIndex,
        // which IS unit-tested); `for-in` keeps it that way.
        var progressions: [Double?] = []
        for index in pageEntries.indices {
            let pageLocator = await self.locator(at: index)
            progressions.append(pageLocator?.locations.totalProgression)
        }

        guard let index = Self.nearestPrecedingIndex(progressions: progressions, current: current) else {
            return nil
        }
        return label(at: index)
    }

    /// Index of the nearest **preceding** page boundary for `current`.
    ///
    /// Among the entries whose progression is non-nil and ≤ `current`, returns
    /// the index of the one with the largest progression. Ties resolve to the
    /// first (lowest-index) boundary — `>` keeps the first, matching the
    /// document-order start of a page. Returns nil when no entry qualifies
    /// (every progression is nil or strictly greater than `current`).
    static func nearestPrecedingIndex(progressions: [Double?], current: Double) -> Int? {
        var bestIndex: Int?
        var bestValue = -Double.greatestFiniteMagnitude
        var i = 0
        while i < progressions.count {
            if let value = progressions[i], value <= current, value > bestValue {
                bestValue = value
                bestIndex = i
            }
            i += 1
        }
        return bestIndex
    }
}
