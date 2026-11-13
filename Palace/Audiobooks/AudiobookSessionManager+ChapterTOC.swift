//
//  AudiobookSessionManager+ChapterTOC.swift
//  Palace
//
//  Chapter TOC normalization, kept as an extension so call sites use
//  `AudiobookSessionManager.<name>`.
//

import PalaceAudiobookToolkit

extension AudiobookSessionManager {
    /// Passthrough: TOC collapse lives in the toolkit's
    /// `AudiobookTableOfContents`. A second collapse here would number chapters
    /// differently from the toolkit's currentChapter / saved position.
    static func normalizedChapters(for toc: AudiobookTableOfContents) -> [Chapter] {
        toc.toc
    }

    /// Test-only spec for the 1.5x oversubdivision THRESHOLD (one chapter per
    /// physical track when `tocCount > trackCount * 1.5`). NOTE: this is no longer
    /// the production collapse seam — `normalizedChapters(for:)` is now a passthrough
    /// and the collapse is implemented in the toolkit's `AudiobookTableOfContents`
    /// (`isOversubdivided` + keep-first). This primitive is retained only to keep the
    /// threshold math pinned by unit tests without constructing toolkit types; it
    /// does not drive any production code path.
    static func normalizedChaptersCount(tocCount: Int, trackCount: Int) -> Int {
        if !ChapterTOCNormalizer.isOversubdivided(tocCount: tocCount, expectedChapterCount: trackCount) {
            return tocCount
        }
        return trackCount
    }
}
