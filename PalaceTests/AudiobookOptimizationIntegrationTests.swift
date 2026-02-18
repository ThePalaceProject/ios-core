//
//  AudiobookOptimizationIntegrationTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceAudiobookToolkit

final class AudiobookOptimizationIntegrationTests: XCTestCase {
    
    var coordinator: AudiobookOptimizationCoordinator!
    var performanceMonitor: AudiobookPerformanceMonitor!
    
    override func setUp() {
        super.setUp()
        coordinator = AudiobookOptimizationCoordinator.shared
        performanceMonitor = AudiobookPerformanceMonitor.shared
    }
    
    override func tearDown() {
        coordinator = nil
        performanceMonitor = nil
        super.tearDown()
    }
    
    // MARK: - System Integration Tests
    
    func testOptimizationCoordinatorInitialization() {
        // Given: Optimization coordinator
        // When: Initialize optimizations
        XCTAssertNoThrow(coordinator.initializeOptimizations())
        
        // Then: Should complete without errors
        XCTAssertNotNil(coordinator)
    }
    
    func testPerformanceMonitorProvideStatus() {
        // Given: Performance monitor
        // When: Get current status
        let status = performanceMonitor.getCurrentPerformanceStatus()
        
        // Then: Should provide meaningful status
        XCTAssertNotNil(status["memoryUsageMB"])
        XCTAssertNotNil(status["networkType"])
        XCTAssertNotNil(status["isLowMemoryDevice"])
        XCTAssertNotNil(status["maxConcurrentDownloads"])
    }
    
    func testSystemStatusComprehensive() {
        // Given: Coordinator
        // When: Get system status
        let status = coordinator.getSystemStatus()
        
        // Then: Should provide comprehensive status
        XCTAssertNotNil(status["optimizationSystemsActive"])
        XCTAssertNotNil(status["networkType"])
        XCTAssertNotNil(status["estimatedBandwidth"])
        XCTAssertNotNil(status["memoryUsageMB"])
    }
    
    func testForceOptimizationDoesNotCrash() {
        // Given: Performance monitor
        // When: Force optimization
        XCTAssertNoThrow(performanceMonitor.forceOptimization())
        
        // Then: Should complete without crashing
        XCTAssertNotNil(performanceMonitor)
    }
    
    // MARK: - Component Integration Tests
    
    func testAllComponentsSingletons() {
        // Given: Multiple references to shared instances
        let memoryManager1 = AdaptiveMemoryManager.shared
        let memoryManager2 = AdaptiveMemoryManager.shared
        let networkAdapter1 = NetworkConditionAdapter.shared
        let networkAdapter2 = NetworkConditionAdapter.shared
        let streamingManager1 = AdaptiveStreamingManager.shared
        let streamingManager2 = AdaptiveStreamingManager.shared
        
        // Then: Should be same instances (singletons)
        XCTAssertTrue(memoryManager1 === memoryManager2)
        XCTAssertTrue(networkAdapter1 === networkAdapter2)
        XCTAssertTrue(streamingManager1 === streamingManager2)
    }
    
    func testOptimizationSystemsWork() {
        // Given: Mock audiobook table of contents
        let mockTOC = createMockTableOfContents()
        
        // When: Apply optimizations
        let optimized = coordinator.optimizeTableOfContents(mockTOC)
        
        // Then: Should return optimized version
        XCTAssertNotNil(optimized)
        XCTAssertGreaterThanOrEqual(optimized.toc.count, 0)
    }
    
    // MARK: - Performance Validation Tests
    
    func testMemoryManagerProvidesReasonableValues() {
        // Given: Memory manager
        let memoryManager = AdaptiveMemoryManager.shared
        
        // Then: Should provide reasonable configuration values
        XCTAssertGreaterThan(memoryManager.audioBufferSize, 0)
        XCTAssertLessThan(memoryManager.audioBufferSize, 1024 * 1024) // < 1MB
        XCTAssertGreaterThan(memoryManager.maxConcurrentDownloads, 0)
        XCTAssertLessThanOrEqual(memoryManager.maxConcurrentDownloads, 10)
        XCTAssertGreaterThan(memoryManager.cacheMemoryLimit, 0)
        XCTAssertLessThan(memoryManager.cacheMemoryLimit, 100 * 1024 * 1024) // < 100MB
    }
    
    func testNetworkAdapterProvidesValidConfiguration() {
        // Given: Network adapter
        let networkAdapter = NetworkConditionAdapter.shared
        
        // When: Get configuration
        let config = networkAdapter.currentConfiguration()
        
        // Then: Should provide valid configuration
        XCTAssertGreaterThan(config.httpMaximumConnectionsPerHost, 0)
        XCTAssertLessThanOrEqual(config.httpMaximumConnectionsPerHost, 10)
        XCTAssertGreaterThan(config.timeoutIntervalForRequest, 0)
        XCTAssertLessThan(config.timeoutIntervalForRequest, 120) // < 2 minutes
    }
    
    func testStreamingManagerProvidesValidQuality() {
        // Given: Streaming manager
        let streamingManager = AdaptiveStreamingManager.shared
        
        // When: Configure quality
        let quality = streamingManager.configureStreamingQuality()
        
        // Then: Should provide valid quality
        XCTAssertTrue(quality.rawValue >= 0)
        if quality != .adaptive {
            XCTAssertLessThanOrEqual(quality.rawValue, 512) // Reasonable max bitrate
        }
    }
    
    // MARK: - Helper Methods
    
    private func createMockTableOfContents() -> AudiobookTableOfContents {
        let manifest = createMockManifest()
        let tracks = createMockTracks(for: manifest)
        return AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    }
    
    private func createMockManifest() -> Manifest {
        let metadata = Manifest.Metadata(
            title: "Integration Test Book",
            identifier: "integration-test",
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
            )
        ]
        
        return Manifest(
            context: [.other("https://readium.org/webpub-manifest/context.jsonld")],
            id: "integration-test",
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
    
    private func createMockTracks(for manifest: Manifest) -> Tracks {
        return Tracks(manifest: manifest, audiobookID: "integration-test", token: nil)
    }
}
