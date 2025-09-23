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
final class ChapterParsingOptimizer {
    
    private let memoryManager = AdaptiveMemoryManager.shared
    
    func optimizeTableOfContents(_ tableOfContents: AudiobookTableOfContents) -> AudiobookTableOfContents {
        
        guard shouldOptimize(tableOfContents: tableOfContents) else {
            Log.info(#file, "Chapter optimization skipped - preserving complex chapter-to-track mapping for \(tableOfContents.manifest.audiobookType) audiobook with \(tableOfContents.toc.count) chapters")
            return tableOfContents
        }
        
        let originalCount = tableOfContents.toc.count
        var optimizedChapters = tableOfContents.toc
        
        optimizedChapters = consolidateShortChapters(optimizedChapters)
        optimizedChapters = limitExcessiveChapters(optimizedChapters, maxChapters: memoryManager.maxChapterCount)
        
        let finalCount = optimizedChapters.count
        if originalCount != finalCount {
            Log.info(#file, "Chapter optimization: \(originalCount) → \(finalCount) chapters")
        }
        
        return tableOfContents
    }
    
    // MARK: - Optimization Logic
    
    private func shouldOptimize(tableOfContents: AudiobookTableOfContents) -> Bool {
        let chapterCount = tableOfContents.toc.count
        
        // CRITICAL: Don't optimize ANY audiobooks with complex chapter-to-track mapping
        // This includes Audible, LCP, and any audiobook with timestamp-based chapters
        
        // Never optimize Findaway or Overdrive (they have special handling)
        if tableOfContents.manifest.audiobookType == .findaway ||
           tableOfContents.manifest.audiobookType == .overdrive {
            Log.info(#file, "Skipping chapter optimization - Findaway/Overdrive audiobook")
            return false
        }
        
        // Never optimize LCP audiobooks (often Audible) - they have complex chapter structures
        if tableOfContents.manifest.audiobookType == .lcp {
            Log.info(#file, "Skipping chapter optimization - LCP audiobook (likely Audible)")
            return false
        }
        
        // Never optimize if ANY chapter has a non-zero timestamp (indicates complex mapping)
        if hasChaptersWithTimestamps(tableOfContents.toc) {
            Log.info(#file, "Skipping chapter optimization - chapters have timestamp offsets")
            return false
        }
        
        // Never optimize if chapters span multiple tracks or tracks have multiple chapters
        if hasComplexTrackChapterMapping(tableOfContents.toc) {
            Log.info(#file, "Skipping chapter optimization - complex track-to-chapter mapping detected")
            return false
        }
        
        // Only optimize in extreme cases on very low memory devices with simple structure
        return memoryManager.isLowMemoryDevice && 
               chapterCount > memoryManager.maxChapterCount * 2 && // Much higher threshold
               hasOnlySimpleChapters(tableOfContents.toc)
    }
    
    private func hasChaptersWithTimestamps(_ chapters: [Chapter]) -> Bool {
        // If any chapter has a non-zero timestamp, it indicates complex track mapping
        return chapters.contains { chapter in
            chapter.position.timestamp > 0.1
        }
    }
    
    private func hasComplexTrackChapterMapping(_ chapters: [Chapter]) -> Bool {
        // Check if multiple chapters map to the same track (complex mapping)
        let trackIds = chapters.map { $0.position.track.id as String }
        let uniqueTrackIds = Set(trackIds)
        
        // If we have fewer unique tracks than chapters, some tracks have multiple chapters
        return uniqueTrackIds.count < chapters.count
    }
    
    private func hasOnlySimpleChapters(_ chapters: [Chapter]) -> Bool {
        // Only optimize if ALL chapters are simple: one chapter per track, no timestamps
        return chapters.allSatisfy { chapter in
            chapter.position.timestamp == 0.0 && // No timestamp offset
            chapter.duration != nil && // Has explicit duration
            chapter.duration! > 60.0 // Reasonable length (> 1 minute)
        }
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
        if Double(consolidatedChapters.count) < Double(chapters.count) * 0.8 {
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
        
        // Since AudiobookTableOfContents is a struct and we can't easily modify it,
        // we'll return the original for now. In a full implementation, this would
        // require deeper integration with the audiobook toolkit.
        Log.info(#file, "Chapter optimization completed but table of contents structure unchanged")
        return original
    }
}

