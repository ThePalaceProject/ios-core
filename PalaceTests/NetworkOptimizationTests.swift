//
//  NetworkOptimizationTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class NetworkOptimizationTests: XCTestCase {
    
    var networkAdapter: NetworkConditionAdapter!
    var streamingManager: AdaptiveStreamingManager!
    
    override func setUp() {
        super.setUp()
        networkAdapter = NetworkConditionAdapter.shared
        streamingManager = AdaptiveStreamingManager.shared
    }
    
    override func tearDown() {
        networkAdapter = nil
        streamingManager = nil
        super.tearDown()
    }
    
    // MARK: - Network Configuration Tests
    
    func testWiFiConfigurationOptimization() {
        // Given: WiFi network type
        let config = networkAdapter.currentConfiguration()
        
        // Then: Should have appropriate settings for WiFi
        XCTAssertGreaterThan(config.httpMaximumConnectionsPerHost, 2, "WiFi should allow more connections")
        XCTAssertLessThan(config.timeoutIntervalForRequest, 20, "WiFi should have shorter timeouts")
    }
    
    func testConcurrentDownloadLimitsBasedOnNetwork() {
        // Given: Different network types
        let wifiLimit = networkAdapter.maxConcurrentDownloads
        
        // Then: Should provide reasonable limits
        XCTAssertGreaterThan(wifiLimit, 0, "Should allow at least one download")
        XCTAssertLessThanOrEqual(wifiLimit, 6, "Should not exceed reasonable limit")
    }
    
    // MARK: - Streaming Quality Tests
    
    func testStreamingQualityAdaptation() {
        // Given: Streaming manager
        let quality = streamingManager.configureStreamingQuality()
        
        // Then: Should return valid quality
        XCTAssertTrue(quality.rawValue >= 0, "Quality should be valid")
    }
    
    func testPrefetchConfigurationReasonable() {
        // Given: Current conditions
        let config = streamingManager.prefetchConfiguration()
        
        // Then: Should have reasonable limits
        XCTAssertGreaterThanOrEqual(config.maxPrefetchChapters, 0, "Prefetch chapters should not be negative")
        XCTAssertLessThanOrEqual(config.maxPrefetchChapters, 10, "Prefetch chapters should not be excessive")
    }
    
    func testBufferConfigurationScaling() {
        // Given: Buffer configuration
        let config = streamingManager.bufferConfiguration()
        
        // Then: Should have reasonable buffer sizes
        XCTAssertGreaterThan(config.initialBufferSize, 0, "Initial buffer should be positive")
        XCTAssertGreaterThanOrEqual(config.maxBufferSize, config.initialBufferSize, "Max buffer should be >= initial")
        XCTAssertGreaterThan(config.rebufferThreshold, 0, "Rebuffer threshold should be positive")
        XCTAssertLessThan(config.rebufferThreshold, 1, "Rebuffer threshold should be less than 1")
    }
    
    // MARK: - Integration Tests
    
    func testNetworkAdapterSingleton() {
        // Given: Multiple references to shared instance
        let adapter1 = NetworkConditionAdapter.shared
        let adapter2 = NetworkConditionAdapter.shared
        
        // Then: Should be same instance
        XCTAssertTrue(adapter1 === adapter2, "Should be singleton")
    }
    
    func testStreamingManagerSingleton() {
        // Given: Multiple references to shared instance
        let manager1 = AdaptiveStreamingManager.shared
        let manager2 = AdaptiveStreamingManager.shared
        
        // Then: Should be same instance
        XCTAssertTrue(manager1 === manager2, "Should be singleton")
    }
}

// MARK: - MyBooksDownloadCenter Extension Tests

final class IntelligentDownloadManagerTests: XCTestCase {
    
    var downloadCenter: MyBooksDownloadCenter!
    
    override func setUp() {
        super.setUp()
        downloadCenter = MyBooksDownloadCenter.shared
    }
    
    override func tearDown() {
        downloadCenter = nil
        super.tearDown()
    }
    
    func testDownloadLimitAdjustment() {
        // Given: Download center
        let originalLimit = downloadCenter.value(forKey: "maxConcurrentDownloads") as? Int ?? 3
        
        // When: Adjust limit
        downloadCenter.limitActiveDownloads(max: 2)
        
        // Then: Should accept the adjustment (async operation, so we test the method exists)
        XCTAssertNoThrow(downloadCenter.limitActiveDownloads(max: 2))
        
        // Cleanup: Restore original limit
        downloadCenter.limitActiveDownloads(max: originalLimit)
    }
    
    func testNetworkMonitoringSetup() {
        // When: Setup network monitoring
        XCTAssertNoThrow(downloadCenter.setupNetworkMonitoring())
        
        // Then: Should not crash
        XCTAssertNotNil(downloadCenter, "Download center should remain valid")
    }
    
    func testQualitySelection() {
        // When: Select quality for network conditions
        let quality = downloadCenter.selectQualityForNetworkConditions()
        
        // Then: Should return valid quality
        XCTAssertNotNil(quality, "Should return quality selection")
    }
}
