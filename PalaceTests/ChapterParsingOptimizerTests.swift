//
//  ChapterParsingOptimizerTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceAudiobookToolkit

final class ChapterParsingOptimizerTests: XCTestCase {
    
    var optimizer: ChapterParsingOptimizer!
    
    override func setUp() {
        super.setUp()
        optimizer = ChapterParsingOptimizer()
    }
    
    override func tearDown() {
        optimizer = nil
        super.tearDown()
    }
    
    // MARK: - Basic Functionality Tests
    
    func testOptimizerExists() {
        // Given: Optimizer instance
        // Then: Should be properly initialized
        XCTAssertNotNil(optimizer)
    }
    
    func testOptimizationPreservesBasicFunctionality() {
        // Given: Mock table of contents
        let mockTOC = createMockTableOfContents()
        
        // When: Optimize table of contents
        let optimized = optimizer.optimizeTableOfContents(mockTOC)
        
        // Then: Should preserve basic functionality
        XCTAssertNotNil(optimized)
        XCTAssertGreaterThan(optimized.toc.count, 0, "Should have chapters")
        XCTAssertNotNil(optimized.manifest, "Should preserve manifest")
        XCTAssertNotNil(optimized.tracks, "Should preserve tracks")
    }
    
    func testOptimizationDoesNotBreakNavigation() {
        // Given: Mock table of contents with multiple chapters
        let mockTOC = createMockTableOfContentsWithMultipleChapters()
        
        // When: Optimize table of contents
        let optimized = optimizer.optimizeTableOfContents(mockTOC)
        
        // Then: Navigation should still work
        guard optimized.toc.count > 1 else {
            XCTFail("Need at least 2 chapters for navigation test")
            return
        }
        
        let firstChapter = optimized.toc[0]
        let nextChapter = optimized.nextChapter(after: firstChapter)
        XCTAssertNotNil(nextChapter, "Navigation should work after optimization")
    }
    
    func testOptimizationPreservesDownloadProgress() {
        // Given: Mock table of contents
        let mockTOC = createMockTableOfContents()
        
        // When: Optimize table of contents
        let optimized = optimizer.optimizeTableOfContents(mockTOC)
        
        // Then: Download progress methods should work
        guard let firstChapter = optimized.toc.first else {
            XCTFail("Should have at least one chapter")
            return
        }
        
        let progress = optimized.downloadProgress(for: firstChapter)
        XCTAssertGreaterThanOrEqual(progress, 0.0)
        XCTAssertLessThanOrEqual(progress, 1.0)
        
        let overallProgress = optimized.overallDownloadProgress
        XCTAssertGreaterThanOrEqual(overallProgress, 0.0)
        XCTAssertLessThanOrEqual(overallProgress, 1.0)
    }
    
    // MARK: - Optimization Behavior Tests
    
    func testOptimizerRespectsSpecialAudiobookTypes() {
        // Given: Mock Findaway audiobook (should not be optimized)
        let findawayTOC = createMockFindawayTableOfContents()
        let originalCount = findawayTOC.toc.count
        
        // When: Optimize
        let optimized = optimizer.optimizeTableOfContents(findawayTOC)
        
        // Then: Should not optimize Findaway audiobooks
        XCTAssertEqual(optimized.toc.count, originalCount, "Findaway audiobooks should not be optimized")
    }
    
    func testOptimizerHandlesEmptyTableOfContents() {
        // Given: Empty table of contents
        let emptyTOC = createEmptyTableOfContents()
        
        // When: Optimize
        let optimized = optimizer.optimizeTableOfContents(emptyTOC)
        
        // Then: Should handle gracefully
        XCTAssertNotNil(optimized)
        XCTAssertEqual(optimized.toc.count, 0, "Empty TOC should remain empty")
    }
    
    // MARK: - Helper Methods
    
    private func createMockTableOfContents() -> AudiobookTableOfContents {
        let manifest = createMockManifest()
        let tracks = createMockTracks()
        return AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    }
    
    private func createMockTableOfContentsWithMultipleChapters() -> AudiobookTableOfContents {
        let manifest = createMockManifestWithMultipleChapters()
        let tracks = createMockTracksWithMultipleChapters()
        return AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    }
    
    private func createMockFindawayTableOfContents() -> AudiobookTableOfContents {
        let manifest = createMockFindawayManifest()
        let tracks = createMockTracks()
        return AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    }
    
    private func createEmptyTableOfContents() -> AudiobookTableOfContents {
        let manifest = createEmptyManifest()
        let tracks = createEmptyTracks()
        return AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    }
    
    private func createMockManifest() -> Manifest {
        let metadata = Manifest.Metadata(
            title: "Test Book",
            identifier: "test-book",
            language: "en"
        )
        
        let readingOrder = [
            Manifest.ReadingOrderItem(
                href: "chapter1.mp3",
                type: "audio/mpeg",
                title: "Chapter 1",
                duration: 300,
                findawayPart: nil,
                findawaySequence: nil,
                properties: nil
            )
        ]
        
        return Manifest(
            context: [.other("https://readium.org/webpub-manifest/context.jsonld")],
            id: "test-book",
            metadata: metadata,
            readingOrder: readingOrder,
            toc: nil,
            spine: nil,
            links: nil,
            linksDictionary: nil,
            resources: nil,
            formatType: nil
        )
    }
    
    private func createMockManifestWithMultipleChapters() -> Manifest {
        let metadata = Manifest.Metadata(
            title: "Test Book with Multiple Chapters",
            identifier: "test-book-multi",
            language: "en"
        )
        
        let readingOrder = [
            Manifest.ReadingOrderItem(
                href: "chapter1.mp3",
                type: "audio/mpeg",
                title: "Chapter 1",
                duration: 300,
                findawayPart: nil,
                findawaySequence: nil,
                properties: nil
            ),
            Manifest.ReadingOrderItem(
                href: "chapter2.mp3",
                type: "audio/mpeg",
                title: "Chapter 2",
                duration: 400,
                findawayPart: nil,
                findawaySequence: nil,
                properties: nil
            ),
            Manifest.ReadingOrderItem(
                href: "chapter3.mp3",
                type: "audio/mpeg",
                title: "Chapter 3",
                duration: 350,
                findawayPart: nil,
                findawaySequence: nil,
                properties: nil
            )
        ]
        
        return Manifest(
            context: [.other("https://readium.org/webpub-manifest/context.jsonld")],
            id: "test-book-multi",
            metadata: metadata,
            readingOrder: readingOrder,
            toc: nil,
            spine: nil,
            links: nil,
            linksDictionary: nil,
            resources: nil,
            formatType: nil
        )
    }
    
    private func createMockFindawayManifest() -> Manifest {
        let metadata = Manifest.Metadata(
            title: "Test Findaway Book",
            identifier: "test-findaway",
            language: "en",
            drmInformation: Manifest.Metadata.DRMInformation(scheme: "http://librarysimplified.org/terms/drm/scheme/FAE")
        )
        
        let readingOrder = [
            Manifest.ReadingOrderItem(
                href: nil,
                type: "audio/mpeg",
                title: "Chapter 1",
                duration: 1800,
                findawayPart: 1,
                findawaySequence: 1,
                properties: nil
            )
        ]
        
        return Manifest(
            context: [.other("https://readium.org/webpub-manifest/context.jsonld")],
            id: "test-findaway",
            metadata: metadata,
            readingOrder: readingOrder,
            toc: nil,
            spine: nil,
            links: nil,
            linksDictionary: nil,
            resources: nil,
            formatType: nil
        )
    }
    
    private func createEmptyManifest() -> Manifest {
        let metadata = Manifest.Metadata(
            title: "Empty Book",
            identifier: "empty-book",
            language: "en"
        )
        
        return Manifest(
            context: [.other("https://readium.org/webpub-manifest/context.jsonld")],
            id: "empty-book",
            metadata: metadata,
            readingOrder: [],
            toc: nil,
            spine: nil,
            links: nil,
            linksDictionary: nil,
            resources: nil,
            formatType: nil
        )
    }
    
    private func createMockTracks() -> Tracks {
        let manifest = createMockManifest()
        return Tracks(manifest: manifest, audiobookID: "test", token: nil)
    }
    
    private func createMockTracksWithMultipleChapters() -> Tracks {
        let manifest = createMockManifestWithMultipleChapters()
        return Tracks(manifest: manifest, audiobookID: "test-multi", token: nil)
    }
    
    private func createEmptyTracks() -> Tracks {
        let manifest = createEmptyManifest()
        return Tracks(manifest: manifest, audiobookID: "empty", token: nil)
    }
}
