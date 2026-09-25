//
//  BookDetailViewModel+ContentGate.swift
//  Palace
//
//  The half-sheet's "is the patron actually waiting" input, kept OUT of
//  `BookDetailViewModel`. That type is under the god-class LOC freeze, and the
//  ratchet's instruction is explicit: land the fix by extracting into a
//  collaborator, not by growing the hub. An earlier revision added a stored
//  provider plus this computed property to the class and pushed it 981 -> 985,
//  which CI caught.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation

extension BookDetailViewModel {

    /// Whether the `.lcpa` must land before this book can be opened — i.e. LCP
    /// streaming is OFF, so the background fetch IS the patron's wait rather
    /// than a prefetch running behind a book that already plays.
    ///
    /// Resolved through the download centre's existing
    /// `lcpStreamingEnabledProvider` rather than a second provider of its own.
    /// An earlier revision stored a duplicate closure on the view model; that
    /// was new surface for a seam the type already had, and it made the two
    /// `HalfSheetProvider` conformers answer the same question by different
    /// routes. `BookCellModel` reads the identical provider, so both now agree
    /// by construction and a test drives them the same way.
    ///
    /// `lcp_audiobook_streaming_enabled` DEFAULTS OFF and is the feature's kill
    /// switch, so the half-sheet must never assume it is on.
    var contentRequiredBeforePlayback: Bool {
        !downloadCenter.lcpStreamingEnabledProvider()
    }
}
