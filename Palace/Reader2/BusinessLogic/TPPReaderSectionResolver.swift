//
//  TPPReaderSectionResolver.swift
//  The Palace Project
//
//  Resolves "which section am I in?" for the DAISY nav-310 "Where am I?"
//  announcement (PP-4527).
//
//  `Locator.title` is only set when the patron arrived via a ToC link, so the
//  section is derived from the nearest preceding ToC/nav entry instead.
//

import Foundation

/// Picks the table-of-contents entry a reading position falls inside.
enum TPPReaderSectionResolver {

    /// One flattened table-of-contents entry, reduced to what ordering needs.
    ///
    /// `progression` is the entry's position WITHIN its resource, present only
    /// when the nav link carries a fragment. A whole-resource entry has none and
    /// is treated as starting at the top of that resource.
    struct Entry: Equatable {
        let title: String
        let resourceIndex: Int
        let progression: Double?

        init(title: String, resourceIndex: Int, progression: Double? = nil) {
            self.title = title
            self.resourceIndex = resourceIndex
            self.progression = progression
        }
    }

    /// The title of the nearest entry at or before the given position, or nil
    /// when the position precedes every entry (front matter before the first nav
    /// target). Nil is a normal outcome, not an error — the announcement simply
    /// omits the section, per the AC.
    ///
    /// Entries are ordered by (resourceIndex, progression) rather than trusted in
    /// array order: a nav document's declaration order is not guaranteed to be
    /// reading order.
    static func section(in entries: [Entry], resourceIndex: Int, progression: Double) -> String? {
        let candidates = entries
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { entry in
                if entry.resourceIndex < resourceIndex { return true }
                guard entry.resourceIndex == resourceIndex else { return false }
                // A position exactly ON an entry is inside it, not before it.
                return (entry.progression ?? 0.0) <= progression
            }

        // `max(by:)` keeps the earlier element on a tie, so the entry declared
        // first in the nav document wins. Fragment-anchored sub-sections of one
        // chapter all tie at 0.0, so this names the chapter rather than an
        // arbitrary sub-heading.
        let best = candidates.max {
            ($0.resourceIndex, $0.progression ?? 0.0) < ($1.resourceIndex, $1.progression ?? 0.0)
        }

        return best?.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
