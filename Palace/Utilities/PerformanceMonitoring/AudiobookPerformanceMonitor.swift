//
//  AudiobookPerformanceMonitor.swift
//  Palace
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import PalaceAudiobookToolkit

/// Monitors audiobook performance and coordinates optimization systems
/// Provides telemetry and automatic adjustments for optimal user experience
final class AudiobookPerformanceMonitor {
    static let shared = AudiobookPerformanceMonitor()
    
    private let memoryManager = AdaptiveMemoryManager.shared
    private let networkAdapter = NetworkConditionAdapter.shared
    private let streamingManager = AdaptiveStreamingManager.shared
    private let chapterOptimizer = ChapterParsingOptimizer()
    
    private let metricsQueue = DispatchQueue(label: "com.palace.audiobook-performance", qos: .utility)
    
    init() {
        setupPerformanceMonitoring()
    }
    
    // MARK: - Performance Monitoring Setup
    
    private func setupPerformanceMonitoring() {
        // Monitor memory pressure events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryPressure),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        Log.info(#file, "AudiobookPerformanceMonitor initialized")
    }
    
    // MARK: - Event Handlers
    
    @objc private func handleMemoryPressure() {
        metricsQueue.async { [weak self] in
            self?.adjustForMemoryPressure()
        }
    }
    
    // MARK: - Performance Adjustments
    
    private func adjustForMemoryPressure() {
        Log.info(#file, "Adjusting for memory pressure")
        
        reduceCacheSizes()
        pauseNonEssentialOperations()
    }
    
    // MARK: - Memory Management
    
    private func reduceCacheSizes() {
        ImageCache.shared.clear()
        
        URLCache.shared.removeAllCachedResponses()
        
        GeneralCache<String, Data>.clearAllCaches()
    }
    
    private func pauseNonEssentialOperations() {
        MyBooksDownloadCenter.shared.pauseAllDownloads()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            MyBooksDownloadCenter.shared.resumeIntelligentDownloads()
        }
    }
    
    // MARK: - Public Interface
    
    /// Get current performance status for debugging
    func getCurrentPerformanceStatus() -> [String: Any] {
        return [
            "isLowMemoryDevice": memoryManager.isLowMemoryDevice,
            "maxConcurrentDownloads": networkAdapter.maxConcurrentDownloads,
            "cacheMemoryLimit": memoryManager.cacheMemoryLimit,
            "audioBufferSize": memoryManager.audioBufferSize
        ]
    }
    
    /// Force a performance optimization cycle
    func forceOptimization() {
        metricsQueue.async { [weak self] in
            self?.adjustForMemoryPressure()
        }
    }
}

// MARK: - Integration Coordinator

/// Coordinates all audiobook optimization systems
final class AudiobookOptimizationCoordinator {
    static let shared = AudiobookOptimizationCoordinator()
    
    private let performanceMonitor = AudiobookPerformanceMonitor.shared
    private let chapterOptimizer = ChapterParsingOptimizer()
    
    /// Initialize audiobook optimization systems
    func initializeOptimizations() {
        Log.info(#file, "Initializing audiobook optimization systems")
        
        // The performance monitor is already initialized via shared instance
        // Other systems are initialized when first accessed
        
        Log.info(#file, "Audiobook optimization systems initialized successfully")
    }
    
    /// Optimize a table of contents using the chapter optimizer
    func optimizeTableOfContents(_ tableOfContents: AudiobookTableOfContents) -> AudiobookTableOfContents {
        return chapterOptimizer.optimizeTableOfContents(tableOfContents)
    }
    
    /// Get comprehensive system status
    func getSystemStatus() -> [String: Any] {
        let performanceStatus = performanceMonitor.getCurrentPerformanceStatus()
        let memoryManager = AdaptiveMemoryManager.shared
        let networkAdapter = NetworkConditionAdapter.shared
        
        var status = performanceStatus
        status["optimizationSystemsActive"] = true
        status["networkType"] = "\(networkAdapter.currentNetworkType)"
        status["estimatedBandwidth"] = "\(networkAdapter.estimatedBandwidthCategory)"
        
        return status
    }
}
