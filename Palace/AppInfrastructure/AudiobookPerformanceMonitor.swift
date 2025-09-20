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
@objc final class AudiobookPerformanceMonitor: NSObject {
    static let shared = AudiobookPerformanceMonitor()
    
    private let memoryManager = AdaptiveMemoryManager.shared
    private let networkAdapter = NetworkConditionAdapter.shared
    private let streamingManager = AdaptiveStreamingManager.shared
    private let chapterOptimizer = ChapterParsingOptimizer()
    
    private var performanceMetrics = AudiobookPerformanceMetrics()
    private let metricsQueue = DispatchQueue(label: "com.palace.audiobook-performance", qos: .utility)
    
    override init() {
        super.init()
        setupPerformanceMonitoring()
    }
    
    // MARK: - Performance Monitoring Setup
    
    private func setupPerformanceMonitoring() {
        // Monitor memory pressure events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryPressure(_:)),
            name: .audiobookMemoryPressure,
            object: nil
        )
        
        // Monitor network condition changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNetworkChange(_:)),
            name: .networkTypeChanged,
            object: nil
        )
        
        // Monitor streaming quality updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStreamingQualityUpdate),
            name: .streamingQualityUpdateNeeded,
            object: nil
        )
        
        // Start periodic performance assessment
        startPeriodicAssessment()
    }
    
    // MARK: - Event Handlers
    
    @objc private func handleMemoryPressure(_ notification: Notification) {
        guard let level = notification.object as? MemoryPressureLevel else { return }
        
        metricsQueue.async { [weak self] in
            self?.recordMemoryPressureEvent(level)
            self?.adjustForMemoryPressure(level)
        }
    }
    
    @objc private func handleNetworkChange(_ notification: Notification) {
        guard let networkType = notification.object as? NetworkConditionAdapter.NetworkType else { return }
        
        metricsQueue.async { [weak self] in
            self?.recordNetworkChange(networkType)
            self?.adjustForNetworkConditions(networkType)
        }
    }
    
    @objc private func handleStreamingQualityUpdate() {
        metricsQueue.async { [weak self] in
            self?.updateStreamingQuality()
        }
    }
    
    // MARK: - Performance Adjustments
    
    private func adjustForMemoryPressure(_ level: MemoryPressureLevel) {
        Log.info(#file, "Adjusting for memory pressure: \(level)")
        
        switch level {
        case .warning:
            // Reduce cache sizes and pause non-essential operations
            reduceCacheSizes()
            pauseNonEssentialOperations()
            
        case .critical:
            // Aggressive memory reclamation
            performAggressiveMemoryReclamation()
        }
        
        // Update metrics
        performanceMetrics.memoryPressureEvents += 1
    }
    
    private func adjustForNetworkConditions(_ networkType: NetworkConditionAdapter.NetworkType) {
        Log.info(#file, "Adjusting for network conditions: \(networkType)")
        
        // Adjust download limits
        let maxDownloads = networkAdapter.maxConcurrentDownloads
        MyBooksDownloadCenter.shared.limitActiveDownloads(max: maxDownloads)
        
        // Update streaming quality
        updateStreamingQuality()
        
        // Update metrics
        performanceMetrics.networkChanges += 1
    }
    
    private func updateStreamingQuality() {
        let recommendedQuality = streamingManager.configureStreamingQuality()
        
        // Notify audiobook players of quality change
        NotificationCenter.default.post(
            name: .audiobookQualityChanged,
            object: recommendedQuality
        )
        
        Log.info(#file, "Updated streaming quality: \(recommendedQuality.rawValue)kbps")
    }
    
    // MARK: - Memory Management
    
    private func reduceCacheSizes() {
        // Clear image cache
        ImageCache.shared.clear()
        
        // Reduce network cache
        URLCache.shared.removeAllCachedResponses()
        
        // Clear general caches
        GeneralCache<String, Data>.clearMemoryCache()
    }
    
    private func pauseNonEssentialOperations() {
        // Pause non-critical downloads
        MyBooksDownloadCenter.shared.pauseAllDownloads()
        
        // Resume after a delay with reduced limits
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            MyBooksDownloadCenter.shared.resumeIntelligentDownloads()
        }
    }
    
    private func performAggressiveMemoryReclamation() {
        // All the warning-level actions plus more
        reduceCacheSizes()
        pauseNonEssentialOperations()
        
        // Additional aggressive measures
        clearAllNonEssentialCaches()
        
        // Force garbage collection hint
        autoreleasepool {
            // This helps trigger memory cleanup
        }
    }
    
    private func clearAllNonEssentialCaches() {
        // Clear any other caches that might exist
        NotificationCenter.default.post(name: .clearAllNonEssentialCaches, object: nil)
    }
    
    // MARK: - Performance Assessment
    
    private func startPeriodicAssessment() {
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.performPerformanceAssessment()
        }
    }
    
    private func performPerformanceAssessment() {
        metricsQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Collect current performance metrics
            self.collectPerformanceMetrics()
            
            // Assess if adjustments are needed
            self.assessPerformanceAndAdjust()
            
            // Log metrics periodically
            if self.performanceMetrics.assessmentCount % 10 == 0 {
                self.logPerformanceMetrics()
            }
            
            self.performanceMetrics.assessmentCount += 1
        }
    }
    
    private func collectPerformanceMetrics() {
        // Collect memory usage
        let memoryStats = MemoryPressureMonitor.shared.getCurrentMemoryUsage()
        performanceMetrics.currentMemoryUsageMB = memoryStats.residentMB
        
        // Collect network status
        performanceMetrics.currentNetworkType = networkAdapter.currentNetworkType
        
        // Collect download status
        performanceMetrics.activeDownloads = MyBooksDownloadCenter.shared.value(forKey: "bookIdentifierToDownloadTask") as? [String: Any]
        
        // Update peak memory usage
        if memoryStats.residentMB > performanceMetrics.peakMemoryUsageMB {
            performanceMetrics.peakMemoryUsageMB = memoryStats.residentMB
        }
    }
    
    private func assessPerformanceAndAdjust() {
        // Check if memory usage is too high
        if performanceMetrics.currentMemoryUsageMB > memoryManager.cacheMemoryLimit / (1024 * 1024) {
            Log.warn(#file, "High memory usage detected: \(performanceMetrics.currentMemoryUsageMB)MB")
            reduceCacheSizes()
        }
        
        // Check if too many downloads are active for current conditions
        let activeDownloadCount = (performanceMetrics.activeDownloads as? [String: Any])?.count ?? 0
        let maxRecommended = networkAdapter.maxConcurrentDownloads
        
        if activeDownloadCount > maxRecommended {
            Log.info(#file, "Reducing active downloads from \(activeDownloadCount) to \(maxRecommended)")
            MyBooksDownloadCenter.shared.limitActiveDownloads(max: maxRecommended)
        }
    }
    
    // MARK: - Metrics Logging
    
    private func logPerformanceMetrics() {
        let metrics = performanceMetrics
        
        Log.info(#file, """
        📊 Audiobook Performance Metrics:
        - Memory: \(String(format: "%.1f", metrics.currentMemoryUsageMB))MB (peak: \(String(format: "%.1f", metrics.peakMemoryUsageMB))MB)
        - Network: \(metrics.currentNetworkType)
        - Active Downloads: \((metrics.activeDownloads as? [String: Any])?.count ?? 0)
        - Memory Pressure Events: \(metrics.memoryPressureEvents)
        - Network Changes: \(metrics.networkChanges)
        - Assessments: \(metrics.assessmentCount)
        - Device: \(memoryManager.isLowMemoryDevice ? "Low Memory" : "Normal Memory")
        """)
        
        // Send to analytics if enabled
        reportMetricsToAnalytics(metrics)
    }
    
    private func reportMetricsToAnalytics(_ metrics: AudiobookPerformanceMetrics) {
        // Report key metrics to analytics for monitoring
        TPPErrorLogger.logError(
            withCode: .appLogicInconsistency, // Using existing code for metrics
            summary: "Audiobook Performance Metrics",
            metadata: [
                "currentMemoryMB": metrics.currentMemoryUsageMB,
                "peakMemoryMB": metrics.peakMemoryUsageMB,
                "networkType": "\(metrics.currentNetworkType)",
                "memoryPressureEvents": metrics.memoryPressureEvents,
                "networkChanges": metrics.networkChanges,
                "isLowMemoryDevice": memoryManager.isLowMemoryDevice,
                "timestamp": Date().timeIntervalSince1970
            ]
        )
    }
    
    // MARK: - Public Interface
    
    /// Get current performance status for debugging
    @objc func getCurrentPerformanceStatus() -> [String: Any] {
        return [
            "memoryUsageMB": performanceMetrics.currentMemoryUsageMB,
            "peakMemoryMB": performanceMetrics.peakMemoryUsageMB,
            "networkType": "\(performanceMetrics.currentNetworkType)",
            "isLowMemoryDevice": memoryManager.isLowMemoryDevice,
            "maxConcurrentDownloads": networkAdapter.maxConcurrentDownloads,
            "cacheMemoryLimit": memoryManager.cacheMemoryLimit,
            "audioBufferSize": memoryManager.audioBufferSize
        ]
    }
    
    /// Force a performance optimization cycle
    @objc func forceOptimization() {
        metricsQueue.async { [weak self] in
            self?.performAggressiveMemoryReclamation()
            self?.adjustForNetworkConditions(self?.networkAdapter.currentNetworkType ?? .unknown)
        }
    }
}

// MARK: - Performance Metrics

private struct AudiobookPerformanceMetrics {
    var currentMemoryUsageMB: Double = 0
    var peakMemoryUsageMB: Double = 0
    var currentNetworkType: NetworkConditionAdapter.NetworkType = .unknown
    var activeDownloads: Any? = nil
    var memoryPressureEvents: Int = 0
    var networkChanges: Int = 0
    var assessmentCount: Int = 0
}

// MARK: - Integration Coordinator

/// Coordinates all audiobook optimization systems
@objc final class AudiobookOptimizationCoordinator: NSObject {
    static let shared = AudiobookOptimizationCoordinator()
    
    private let performanceMonitor = AudiobookPerformanceMonitor.shared
    private let chapterOptimizer = ChapterParsingOptimizer()
    
    /// Initialize audiobook optimization systems
    @objc func initializeOptimizations() {
        Log.info(#file, "Initializing audiobook optimization systems")
        
        // Setup network monitoring in download center
        MyBooksDownloadCenter.shared.setupNetworkMonitoring()
        
        // The performance monitor is already initialized via shared instance
        // Other systems are initialized when first accessed
        
        Log.info(#file, "Audiobook optimization systems initialized successfully")
    }
    
    /// Optimize a table of contents using the chapter optimizer
    @objc func optimizeTableOfContents(_ tableOfContents: AudiobookTableOfContents) -> AudiobookTableOfContents {
        return chapterOptimizer.optimizeTableOfContents(tableOfContents)
    }
    
    /// Get comprehensive system status
    @objc func getSystemStatus() -> [String: Any] {
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

// MARK: - Notification Names

extension Notification.Name {
    static let audiobookQualityChanged = Notification.Name("AudiobookQualityChanged")
    static let clearAllNonEssentialCaches = Notification.Name("ClearAllNonEssentialCaches")
}
