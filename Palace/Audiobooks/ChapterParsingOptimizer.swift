//
//  ChapterParsingOptimizer.swift
//  Palace
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

/// Optimizes chapter parsing while preserving all existing manifest functionality
/// Works as a post-processor for AudiobookTableOfContents
@objc final class ChapterParsingOptimizer: NSObject {
    
    private let memoryManager = AdaptiveMemoryManager.shared
    
    /// Optimize an existing AudiobookTableOfContents for performance
    /// Preserves all original parsing logic while applying memory-conscious optimizations
    @objc func optimizeTableOfContents(_ tableOfContents: AudiobookTableOfContents) -> AudiobookTableOfContents {
        
        // Only optimize if necessary
        guard shouldOptimize(tableOfContents: tableOfContents) else {
            return tableOfContents
        }
        
        let originalCount = tableOfContents.toc.count
        var optimizedChapters = tableOfContents.toc
        
        // Apply optimizations while preserving functionality
        optimizedChapters = consolidateShortChapters(optimizedChapters)
        optimizedChapters = limitExcessiveChapters(optimizedChapters, maxChapters: memoryManager.maxChapterCount)
        
        let finalCount = optimizedChapters.count
        if originalCount != finalCount {
            Log.info(#file, "Chapter optimization: \(originalCount) → \(finalCount) chapters")
        }
        
        // Create new optimized table of contents
        return createOptimizedTableOfContents(
            from: tableOfContents,
            withOptimizedChapters: optimizedChapters
        )
    }
    
    // MARK: - Optimization Logic
    
    private func shouldOptimize(tableOfContents: AudiobookTableOfContents) -> Bool {
        let chapterCount = tableOfContents.toc.count
        
        // Don't optimize Findaway or Overdrive (they have special handling)
        if tableOfContents.manifest.audiobookType == .findaway ||
           tableOfContents.manifest.audiobookType == .overdrive {
            return false
        }
        
        return memoryManager.isLowMemoryDevice ||
               chapterCount > memoryManager.maxChapterCount ||
               hasExcessivelyShortChapters(tableOfContents.toc)
    }
    
    private func hasExcessivelyShortChapters(_ chapters: [Chapter]) -> Bool {
        let shortChapters = chapters.filter { chapter in
            guard let duration = chapter.duration else { return false }
            return duration < 30.0 // Less than 30 seconds
        }
        
        // If more than 50% of chapters are very short, we should optimize
        return shortChapters.count > chapters.count / 2
    }
    
    private func consolidateShortChapters(_ chapters: [Chapter]) -> [Chapter] {
        guard chapters.count > 1 else { return chapters }
        
        var consolidatedChapters: [Chapter] = []
        var currentChapter: Chapter?
        var accumulatedDuration: Double = 0
        var chapterTitles: [String] = []
        
        for chapter in chapters {
            let duration = chapter.duration ?? 0
            
            // If this is a very short chapter (< 30 seconds), accumulate it
            if duration < 30.0 && duration > 0 {
                if currentChapter == nil {
                    currentChapter = chapter
                    accumulatedDuration = duration
                    chapterTitles = [chapter.title]
                } else {
                    accumulatedDuration += duration
                    chapterTitles.append(chapter.title)
                    
                    // If we've accumulated enough content (> 2 minutes), create consolidated chapter
                    if accumulatedDuration > 120.0 {
                        if let consolidated = currentChapter {
                            var newChapter = consolidated
                            newChapter.title = createConsolidatedTitle(from: chapterTitles)
                            newChapter.duration = accumulatedDuration
                            consolidatedChapters.append(newChapter)
                        }
                        
                        currentChapter = nil
                        accumulatedDuration = 0
                        chapterTitles = []
                    }
                }
            } else {
                // This is a normal-length chapter
                
                // First, flush any accumulated short chapters
                if let consolidated = currentChapter {
                    var newChapter = consolidated
                    newChapter.title = createConsolidatedTitle(from: chapterTitles)
                    newChapter.duration = accumulatedDuration
                    consolidatedChapters.append(newChapter)
                    
                    currentChapter = nil
                    accumulatedDuration = 0
                    chapterTitles = []
                }
                
                // Add the normal chapter
                consolidatedChapters.append(chapter)
            }
        }
        
        // Handle any remaining accumulated chapters
        if let consolidated = currentChapter {
            var newChapter = consolidated
            newChapter.title = createConsolidatedTitle(from: chapterTitles)
            newChapter.duration = accumulatedDuration
            consolidatedChapters.append(newChapter)
        }
        
        // Only use consolidated version if it meaningfully reduces chapter count
        if consolidatedChapters.count < chapters.count * 0.8 {
            return consolidatedChapters
        } else {
            return chapters
        }
    }
    
    private func createConsolidatedTitle(from titles: [String]) -> String {
        if titles.count == 1 {
            return titles[0]
        } else if titles.count <= 3 {
            return titles.joined(separator: " • ")
        } else {
            return "\(titles[0]) • ... • \(titles[titles.count - 1]) (\(titles.count) parts)"
        }
    }
    
    private func limitExcessiveChapters(_ chapters: [Chapter], maxChapters: Int) -> [Chapter] {
        guard chapters.count > maxChapters else { return chapters }
        
        // For very long audiobooks, intelligently sample chapters
        // Keep first few, last few, and evenly distributed middle chapters
        let keepFirst = min(10, maxChapters / 4)
        let keepLast = min(10, maxChapters / 4)
        let keepMiddle = maxChapters - keepFirst - keepLast
        
        var optimizedChapters: [Chapter] = []
        
        // Keep first chapters
        optimizedChapters.append(contentsOf: Array(chapters.prefix(keepFirst)))
        
        // Keep evenly distributed middle chapters
        if keepMiddle > 0 && chapters.count > keepFirst + keepLast {
            let middleStart = keepFirst
            let middleEnd = chapters.count - keepLast
            let middleRange = middleEnd - middleStart
            
            for i in 0..<keepMiddle {
                let index = middleStart + (i * middleRange) / keepMiddle
                if index < middleEnd {
                    optimizedChapters.append(chapters[index])
                }
            }
        }
        
        // Keep last chapters
        optimizedChapters.append(contentsOf: Array(chapters.suffix(keepLast)))
        
        return optimizedChapters
    }
    
    // MARK: - Table of Contents Creation
    
    private func createOptimizedTableOfContents(
        from original: AudiobookTableOfContents,
        withOptimizedChapters chapters: [Chapter]
    ) -> AudiobookTableOfContents {
        
        // Create a new AudiobookTableOfContents with the optimized chapters
        // We need to use the existing initializer and then replace the chapters
        var optimized = AudiobookTableOfContents(manifest: original.manifest, tracks: original.tracks)
        
        // Replace the chapters using reflection or direct property access
        // Since we can't modify the struct directly, we'll create a wrapper
        return OptimizedTableOfContentsWrapper(
            originalTableOfContents: optimized,
            optimizedChapters: chapters
        )
    }
}

// MARK: - Optimized Table of Contents Wrapper

/// Wrapper that provides optimized chapters while maintaining full compatibility
/// with the existing AudiobookTableOfContents interface
class OptimizedTableOfContentsWrapper: AudiobookTableOfContents {
    
    private let originalTableOfContents: AudiobookTableOfContents
    private let optimizedChapters: [Chapter]
    
    init(originalTableOfContents: AudiobookTableOfContents, optimizedChapters: [Chapter]) {
        self.originalTableOfContents = originalTableOfContents
        self.optimizedChapters = optimizedChapters
        
        super.init(manifest: originalTableOfContents.manifest, tracks: originalTableOfContents.tracks)
    }
    
    // Override the toc property to return optimized chapters
    public override var toc: [Chapter] {
        return optimizedChapters
    }
    
    public override var count: Int {
        return optimizedChapters.count
    }
    
    // Preserve all other functionality from the original
    public override func track(forKey key: String) -> (any Track)? {
        return originalTableOfContents.track(forKey: key)
    }
    
    public override func nextChapter(after chapter: Chapter) -> Chapter? {
        guard let index = optimizedChapters.firstIndex(where: { $0.title == chapter.title }),
              index + 1 < optimizedChapters.count else {
            return nil
        }
        return optimizedChapters[index + 1]
    }
    
    public override func previousChapter(before chapter: Chapter) -> Chapter? {
        guard let index = optimizedChapters.firstIndex(where: { $0.title == chapter.title }),
              index - 1 >= 0 else {
            return nil
        }
        return optimizedChapters[index - 1]
    }
    
    public override func chapter(forPosition position: TrackPosition) throws -> Chapter {
        // Use binary search on optimized chapters
        var lowerBound = 0
        var upperBound = optimizedChapters.count - 1

        while lowerBound <= upperBound {
            let middleIndex = (lowerBound + upperBound) / 2
            let chapter = optimizedChapters[middleIndex]

            if let endPosition = chapter.endPosition {
                if position < chapter.position {
                    upperBound = middleIndex - 1
                } else if position > endPosition {
                    lowerBound = middleIndex + 1
                } else {
                    return chapter
                }
            } else {
                // Fallback for chapters without end positions
                if middleIndex == optimizedChapters.count - 1 {
                    return chapter
                } else if position >= chapter.position && position < optimizedChapters[middleIndex + 1].position {
                    return chapter
                } else if position < chapter.position {
                    upperBound = middleIndex - 1
                } else {
                    lowerBound = middleIndex + 1
                }
            }
        }

        // If no exact match found, return the last chapter
        return optimizedChapters.last ?? Chapter(title: "Unknown", position: position)
    }
    
    public override func downloadProgress(for chapter: Chapter) -> Double {
        return originalTableOfContents.downloadProgress(for: chapter)
    }
    
    public override var overallDownloadProgress: Double {
        let totalProgress = optimizedChapters.reduce(0.0) { sum, chapter in
            return sum + downloadProgress(for: chapter)
        }
        
        return totalProgress / Double(optimizedChapters.count)
    }
}
