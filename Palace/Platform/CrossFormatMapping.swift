//
//  CrossFormatMapping.swift
//  Palace
//
//  Maps reading positions between EPUB and audiobook formats for the same title.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A mapping between an EPUB chapter and an audiobook chapter.
struct ChapterMapping: Codable, Equatable, Sendable {
    /// Zero-based EPUB chapter index.
    let epubChapterIndex: Int
    /// Zero-based audiobook chapter index.
    let audiobookChapterIndex: Int
    /// Optional scaling factor for progress within the chapter.
    /// A value of 2.0 means the EPUB chapter covers roughly twice the content
    /// of the audiobook chapter.
    let progressScale: Double

    init(epubChapterIndex: Int, audiobookChapterIndex: Int, progressScale: Double = 1.0) {
        self.epubChapterIndex = epubChapterIndex
        self.audiobookChapterIndex = audiobookChapterIndex
        self.progressScale = progressScale
    }
}

/// Maps positions between EPUB and audiobook formats for the same book.
struct CrossFormatMapping: Codable, Equatable, Sendable {
    /// The book identifier this mapping applies to.
    let bookID: String

    /// Chapter-level mappings between EPUB and audiobook.
    let chapterMappings: [ChapterMapping]

    /// Total number of EPUB chapters.
    let epubChapterCount: Int

    /// Total number of audiobook chapters.
    let audiobookChapterCount: Int

    // MARK: - Conversion

    /// Convert an EPUB position to an estimated audiobook position.
    func toAudiobookPosition(from epubPosition: ReadingPosition) -> ReadingPosition? {
        guard epubPosition.format == .epub,
              let epubChapter = epubPosition.chapterIndex else {
            return nil
        }

        // Find the best matching chapter mapping
        guard let mapping = bestMapping(forEpubChapter: epubChapter) else {
            // Fall back to proportional mapping
            return proportionalAudiobookPosition(from: epubPosition)
        }

        return .audiobook(
            bookID: epubPosition.bookID,
            chapterIndex: mapping.audiobookChapterIndex,
            timeOffset: 0, // We can't estimate time without chapter duration info
            overallProgress: epubPosition.overallProgress
        )
    }

    /// Convert an audiobook position to an estimated EPUB position.
    func toEpubPosition(from audiobookPosition: ReadingPosition) -> ReadingPosition? {
        guard audiobookPosition.format == .audiobook,
              let abChapter = audiobookPosition.audiobookChapterIndex else {
            return nil
        }

        // Find the best matching chapter mapping
        guard let mapping = bestMapping(forAudiobookChapter: abChapter) else {
            // Fall back to proportional mapping
            return proportionalEpubPosition(from: audiobookPosition)
        }

        return .epub(
            bookID: audiobookPosition.bookID,
            chapterIndex: mapping.epubChapterIndex,
            chapterProgress: 0,
            overallProgress: audiobookPosition.overallProgress
        )
    }

    // MARK: - Auto-Generation

    /// Create a simple 1:1 mapping when chapter counts are equal.
    static func oneToOne(bookID: String, chapterCount: Int) -> CrossFormatMapping {
        let mappings = (0..<chapterCount).map { i in
            ChapterMapping(epubChapterIndex: i, audiobookChapterIndex: i)
        }
        return CrossFormatMapping(
            bookID: bookID,
            chapterMappings: mappings,
            epubChapterCount: chapterCount,
            audiobookChapterCount: chapterCount
        )
    }

    /// Create a proportional mapping when chapter counts differ.
    static func proportional(bookID: String, epubChapterCount: Int, audiobookChapterCount: Int) -> CrossFormatMapping {
        guard epubChapterCount > 0, audiobookChapterCount > 0 else {
            return CrossFormatMapping(bookID: bookID, chapterMappings: [], epubChapterCount: epubChapterCount, audiobookChapterCount: audiobookChapterCount)
        }

        let ratio = Double(audiobookChapterCount) / Double(epubChapterCount)
        var mappings: [ChapterMapping] = []

        for i in 0..<epubChapterCount {
            let abChapter = Int(Double(i) * ratio)
            let clampedAB = min(abChapter, audiobookChapterCount - 1)
            mappings.append(ChapterMapping(
                epubChapterIndex: i,
                audiobookChapterIndex: clampedAB,
                progressScale: ratio
            ))
        }

        return CrossFormatMapping(
            bookID: bookID,
            chapterMappings: mappings,
            epubChapterCount: epubChapterCount,
            audiobookChapterCount: audiobookChapterCount
        )
    }

    // MARK: - Private

    private func bestMapping(forEpubChapter chapter: Int) -> ChapterMapping? {
        // Exact match first
        if let exact = chapterMappings.first(where: { $0.epubChapterIndex == chapter }) {
            return exact
        }
        // Nearest lower chapter
        return chapterMappings
            .filter { $0.epubChapterIndex <= chapter }
            .max(by: { $0.epubChapterIndex < $1.epubChapterIndex })
    }

    private func bestMapping(forAudiobookChapter chapter: Int) -> ChapterMapping? {
        if let exact = chapterMappings.first(where: { $0.audiobookChapterIndex == chapter }) {
            return exact
        }
        return chapterMappings
            .filter { $0.audiobookChapterIndex <= chapter }
            .max(by: { $0.audiobookChapterIndex < $1.audiobookChapterIndex })
    }

    private func proportionalAudiobookPosition(from epub: ReadingPosition) -> ReadingPosition? {
        guard epubChapterCount > 0, audiobookChapterCount > 0,
              let epubChapter = epub.chapterIndex else { return nil }

        let ratio = Double(audiobookChapterCount) / Double(epubChapterCount)
        let abChapter = min(Int(Double(epubChapter) * ratio), audiobookChapterCount - 1)

        return .audiobook(
            bookID: epub.bookID,
            chapterIndex: abChapter,
            timeOffset: 0,
            overallProgress: epub.overallProgress
        )
    }

    private func proportionalEpubPosition(from ab: ReadingPosition) -> ReadingPosition? {
        guard epubChapterCount > 0, audiobookChapterCount > 0,
              let abChapter = ab.audiobookChapterIndex else { return nil }

        let ratio = Double(epubChapterCount) / Double(audiobookChapterCount)
        let epubChapter = min(Int(Double(abChapter) * ratio), epubChapterCount - 1)

        return .epub(
            bookID: ab.bookID,
            chapterIndex: epubChapter,
            chapterProgress: 0,
            overallProgress: ab.overallProgress
        )
    }
}
