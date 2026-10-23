//
//  AudiobookMorphingPlayerView+Text.swift
//  Palace
//
//  The player's pure text and value helpers, kept apart from the view body.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

extension AudiobookMorphingPlayerView {
    /// PP-4971: phrase the whole-book figure in wall-clock time at the speed the
    /// patron is listening at, not in book time.
    ///
    /// This is the "how much longer will this take me" number, so it has to
    /// answer that question — a 2× listener was previously told hours remained
    /// on a book they were about to finish. The chapter timecode beside the
    /// scrubber deliberately does NOT get this treatment: it has to keep
    /// agreeing with the scrubber position and the chapter length.
    ///
    /// The rate division itself is `AudiobookPlaybackModel.remainingWallClock`,
    /// shared with the toolkit player so the two cannot drift apart again.
    nonisolated static func wholeBookRemainingText(
        bookTimeRemaining: TimeInterval,
        rate: PlaybackRate
    ) -> String {
        let remaining = AudiobookPlaybackModel.remainingWallClock(
            bookTimeRemaining: bookTimeRemaining,
            rate: rate
        )
        let hrs = Int(remaining) / 3600
        let mins = (Int(remaining) % 3600) / 60
        if hrs > 0 { return String(format: "%d hr %02d min remaining", hrs, mins) }
        return String(format: "%d min remaining", mins)
    }

    /// VoiceOver label for the determinate download overlay. The overlay
    /// visually shows cover + title + author + progress, but
    /// `.accessibilityElement(children: .ignore)` collapses those children — so
    /// the label must carry the title/author itself, or a blind patron hears
    /// only a bare percentage for the up-to-180s download. Progress is clamped
    /// so a transiently out-of-range value never announces "-4%" / "142%".
    nonisolated static func downloadingAccessibilityLabel(
        title: String?,
        authors: String?,
        progress: Double
    ) -> String {
        let pct = Int((min(max(progress, 0), 1)) * 100)
        var parts = ["\(Strings.Generic.audiobookDownloading), \(pct)%"]
        if let title, !title.isEmpty { parts.append(title) }
        if let authors, !authors.isEmpty { parts.append(authors) }
        return parts.joined(separator: ". ")
    }

    /// Resolves the rate the speed chip should display. Only adopts the session's
    /// rate once a manager is bound — pre-bind, `currentPlaybackRate` returns the
    /// default 1.0× (no player yet), which must NOT overwrite the chip, or a
    /// freshly-reopened book (whose persisted rate the toolkit restores on bind)
    /// would show 1.0× while playing faster. When bound, the session rate is the
    /// source of truth. Pure so the sync decision is unit-tested for both phases.
    nonisolated static func displayRate(
        sessionRate: PlaybackRate,
        isBound: Bool,
        fallback: PlaybackRate
    ) -> PlaybackRate {
        isBound ? sessionRate : fallback
    }

    /// Maps a bookmark-add failure to an app-side localized toast string. The
    /// toolkit's `BookmarkError` is public but its `localizedDescription` is
    /// module-internal (unreachable here), so the raw `Error.localizedDescription`
    /// would surface the useless "operation couldn't be completed" text. Match
    /// the two known cases to faithful app-side copy; anything else falls back to
    /// the generic add-failed string. Static + pure so it's unit-testable.
    static func bookmarkErrorMessage(for error: Error) -> String {
        switch error {
        case BookmarkError.bookmarkAlreadyExists:
            return Strings.Generic.bookmarkAlreadyExists
        case BookmarkError.bookmarkFailedToSave:
            return Strings.Generic.bookmarkFailedToSave
        default:
            return Strings.Generic.bookmarkAddFailed
        }
    }

    /// Whether a toast string represents a failure (error icon) vs. a success
    /// (bookmark icon). Success is only the bookmark-added string; every failure
    /// copy — the generic add-failed plus the two mapped `BookmarkError` cases —
    /// shows the error glyph. Static + pure so it's unit-testable.
    static func toastIsError(_ text: String) -> Bool {
        text != Strings.Generic.bookmarkAdded
            && (text.localizedCaseInsensitiveContains("error")
                || text == Strings.Generic.bookmarkAddFailed
                || text == Strings.Generic.bookmarkAlreadyExists
                || text == Strings.Generic.bookmarkFailedToSave)
    }
}
