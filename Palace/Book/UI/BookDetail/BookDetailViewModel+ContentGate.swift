//
//  BookDetailViewModel+ContentGate.swift
//  Palace
//
//  The half-sheet's "is the patron actually waiting" input, kept in an
//  extension because `BookDetailViewModel` is under a CI-enforced LOC freeze.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation

extension BookDetailViewModel {

    /// Whether the `.lcpa` must land before this book can be opened — i.e. LCP
    /// streaming is OFF, so the background fetch IS the patron's wait rather
    /// than a prefetch running behind a book that already plays.
    ///
    /// Reads the download centre's `lcpStreamingEnabledProvider`, the same
    /// provider `BookCellModel` uses, so both `HalfSheetProvider` conformers
    /// agree by construction.
    ///
    /// `lcp_audiobook_streaming_enabled` defaults off and is the feature's kill
    /// switch, so the half-sheet must never assume it is on.
    var contentRequiredBeforePlayback: Bool {
        !downloadCenter.lcpStreamingEnabledProvider()
    }
}
