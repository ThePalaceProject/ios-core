//
//  ChapterScrubberModel+Publication.swift
//  The Palace Project
//
//  PP-5006: builds a `ChapterScrubberModel` from a Readium `Publication`.
//
//  Runs once per opened book, off the drag path. `publication.locate(_ link:)`
//  carries no `totalProgression`, so a TOC entry's book-wide start is taken from
//  the first position of the resource its href points into. Known limit: TOC
//  entries that point at fragments of one resource collapse to a single tick.
//

import Foundation
@preconcurrency import ReadiumShared

extension ChapterScrubberModel {

    /// An empty model — nothing to scrub. Used before the real one loads and
    /// when the publication reports neither chapters nor positions.
    static let empty = ChapterScrubberModel(chapters: [], positionProgressions: [])

    /// Reads the table of contents and the position list, and reduces them to
    /// the two sorted arrays the drag path needs.
    static func make(from publication: Publication) async -> ChapterScrubberModel {
        let toc = await publication.tableOfContents().getOrNil() ?? []
        let positionsByResource = await publication.positionsByReadingOrder().getOrNil() ?? []

        let readingOrder = publication.readingOrder
        let entries: [TOCEntry] = flatten(toc).compactMap { link in
            guard
                let title = link.title,
                let index = readingOrder.firstIndexWithHREF(link.url())
            else {
                return nil
            }
            return TOCEntry(title: title, readingOrderIndex: index)
        }

        return ChapterScrubberModel(
            chapters: chapters(
                for: entries,
                firstProgressionByResource: positionsByResource.map { $0.first?.locations.totalProgression }
            ),
            positionProgressions: positionsByResource
                .flatMap { $0 }
                .compactMap { $0.locations.totalProgression }
        )
    }

    /// A table-of-contents entry resolved to the spine resource it points into.
    struct TOCEntry: Equatable, Sendable {
        let title: String
        let readingOrderIndex: Int
    }

    /// Pairs each table-of-contents entry with the book-wide progression of the
    /// resource it points into. Entries whose resource is out of range, or whose
    /// resource reports no positions, are dropped.
    static func chapters(
        for entries: [TOCEntry],
        firstProgressionByResource: [Double?]
    ) -> [Chapter] {
        entries.compactMap { entry in
            guard
                firstProgressionByResource.indices.contains(entry.readingOrderIndex),
                let start = firstProgressionByResource[entry.readingOrderIndex]
            else {
                return nil
            }
            return Chapter(title: entry.title, startProgression: start)
        }
    }

    /// Depth-first flattening of the nested table of contents. Sub-entries are
    /// kept: they are the finest structure the book offers, and `init` collapses
    /// any that turn out to share a start.
    private static func flatten(_ links: [Link]) -> [Link] {
        links.flatMap { [$0] + flatten($0.children) }
    }
}
