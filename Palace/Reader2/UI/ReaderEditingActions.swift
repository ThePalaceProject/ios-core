//
//  ReaderEditingActions.swift
//  Palace
//
//  PP-4297: Single decision point for the Readium editing-action list both
//  readers (EPUB and PDF) hand to their navigator configuration. Gating on
//  `TPPBook.isDRMProtected` here keeps the EPUB and PDF reader call sites
//  consistent — adding a new DRM scheme only requires updating the
//  predicate, not every reader.
//

import Foundation
import ReadiumNavigator

enum ReaderEditingActions {

    /// Returns the editing-actions list for the reader presenting `book`.
    ///
    /// - DRM-protected book → `[]`. The reader's navigator gets no editing
    ///   actions and the system text-selection menu does not appear on
    ///   long-press. Custom actions supplied via `appending` are also
    ///   suppressed — a non-empty list would surface the menu.
    /// - Non-DRM book → Readium's `EditingAction.defaultActions`
    ///   (`copy`, `share`, `lookup`, `translate`) plus any caller-supplied
    ///   custom actions (e.g. the EPUB reader's Highlight action).
    /// - Sample preview of any book → treated as non-DRM. Samples are
    ///   open-access preview content even when the parent title is
    ///   DRM-protected.
    static func resolve(
        for book: TPPBook,
        isSample: Bool = false,
        appending custom: [EditingAction] = []
    ) -> [EditingAction] {
        let blocked = book.isDRMProtected && !isSample
        guard !blocked else { return [] }
        return EditingAction.defaultActions + custom
    }
}
