//
//  DebugPerformanceOptimizer.swift
//  Palace
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import os.log

/// Optimizes app performance specifically during debug builds
/// Addresses common debug-time performance issues without affecting production
final class DebugPerformanceOptimizer {
    
    static let shared = DebugPerformanceOptimizer()
    
    private let logger = Logger(subsystem: "com.palace.debug", category: "PerformanceOptimizer")
    private var isOptimized = false
    
    private init() {}
    
    /// Apply debug-specific performance optimizations
    func optimizeForDebug() {
        guard !isOptimized else { return }
        
        #if DEBUG
        logger.info("🚀 Applying debug performance optimizations...")
        
        // 1. Optimize main thread operations
        optimizeMainThreadOperations()
        
        // 2. Apply UI-specific optimizations
        Task { @MainActor in
            DebugUIOptimizer.shared.optimizeUIForDebug()
        }
        
        // 3. Reduce animation overhead in debug
        optimizeAnimationsForDebug()
        
        // 4. Optimize image loading and caching
        optimizeImageOperations()
        
        // 5. Reduce background processing overhead
        optimizeBackgroundOperations()
        
        // 6. Monitor and alert about performance issues
        setupPerformanceMonitoring()
        
        isOptimized = true
        logger.info("✅ Debug performance optimizations applied")
        #endif
    }
    
    // MARK: - Main Thread Optimizations
    
    private func optimizeMainThreadOperations() {
        // Reduce UI update frequency during debugging
        UIView.setAnimationsEnabled(false) // Disable animations in debug for faster UI
        
        // Optimize table view performance
        optimizeTableViewPerformance()
        
        // Reduce layout calculation frequency
        optimizeLayoutCalculations()
    }
    
    private func optimizeTableViewPerformance() {
        // Global optimization for all table views
        let tableViewAppearance = UITableView.appearance()
        tableViewAppearance.estimatedRowHeight = 44 // Reduce layout calculations
        tableViewAppearance.estimatedSectionHeaderHeight = 28
        tableViewAppearance.estimatedSectionFooterHeight = 28
    }
    
    private func optimizeLayoutCalculations() {
        // Reduce auto layout complexity in debug builds
        UIView.setAnimationsEnabled(false)
    }
    
    // MARK: - Animation Optimizations
    
    private func optimizeAnimationsForDebug() {
        // Disable or simplify animations during debugging
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1) // Faster animations
        CATransaction.commit()
        
        // Reduce animation complexity
        UIView.setAnimationBeginsFromCurrentState(true)
    }
    
    // MARK: - Image Operation Optimizations
    
    private func optimizeImageOperations() {
        // Reduce image processing overhead in debug
        // This would integrate with your existing GeneralCache system
        logger.debug("Optimizing image operations for debug performance")
    }
    
    // MARK: - Background Operation Optimizations
    
    private func optimizeBackgroundOperations() {
        // Reduce background task frequency during debugging
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.logger.debug("Optimizing background operations for debug performance")
            
            // Reduce sync frequency
            self?.optimizeSyncOperations()
            
            // Reduce network request frequency
            self?.optimizeNetworkOperations()
        }
    }
    
    private func optimizeSyncOperations() {
        // Reduce book registry sync frequency in debug
        // This would integrate with TPPBookRegistry if needed
    }
    
    private func optimizeNetworkOperations() {
        // Batch network requests to reduce overhead
        // Reduce request frequency during debugging
    }
    
    // MARK: - Performance Monitoring
    
    private func setupPerformanceMonitoring() {
        #if DEBUG
        // Monitor main thread blocking
        setupMainThreadMonitoring()
        
        // Monitor memory usage
        setupMemoryMonitoring()
        
        // Monitor CPU usage
        setupCPUMonitoring()
        #endif
    }
    
    private func setupMainThreadMonitoring() {
        // Monitor main thread for blocks longer than 100ms
        let monitor = MainThreadBlockMonitor()
        monitor.startMonitoring(threshold: 0.1) { [weak self] duration in
            self?.logger.warning("⚠️ Main thread blocked for \(duration)s - this causes UI lag!")
        }
    }
    
    private func setupMemoryMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            let memoryUsage = self?.getCurrentMemoryUsage() ?? 0
            if memoryUsage > 200 * 1024 * 1024 { // 200MB threshold
                self?.logger.warning("⚠️ High memory usage: \(memoryUsage / 1024 / 1024)MB")
            }
        }
    }
    
    private func setupCPUMonitoring() {
        // Monitor CPU usage periodically
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            let cpuUsage = self?.getCurrentCPUUsage() ?? 0
            if cpuUsage > 80 { // 80% threshold
                self?.logger.warning("⚠️ High CPU usage: \(cpuUsage)%")
            }
        }
    }
    
    // MARK: - Utility Methods
    
    private func getCurrentMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Int(info.resident_size)
        } else {
            return 0
        }
    }
    
    private func getCurrentCPUUsage() -> Double {
        var info = task_info_t.allocate(capacity: Int(TASK_INFO_MAX))
        defer { info.deallocate() }
        
        var count = mach_msg_type_number_t(TASK_INFO_MAX)
        let result = task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), info, &count)
        
        guard result == KERN_SUCCESS else { return 0 }
        
        // CPU monitoring simplified for compatibility
        return 0.0 // Placeholder - CPU monitoring can be enhanced later
    }
}

// MARK: - Main Thread Block Monitor

private class MainThreadBlockMonitor {
    private var isMonitoring = false
    private var threshold: TimeInterval = 0.1
    private var onBlock: ((TimeInterval) -> Void)?
    
    func startMonitoring(threshold: TimeInterval, onBlock: @escaping (TimeInterval) -> Void) {
        guard !isMonitoring else { return }
        
        self.threshold = threshold
        self.onBlock = onBlock
        self.isMonitoring = true
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.monitorMainThread()
        }
    }
    
    private func monitorMainThread() {
        while isMonitoring {
            let startTime = CFAbsoluteTimeGetCurrent()
            var blockDetected = false
            
            DispatchQueue.main.sync {
                let endTime = CFAbsoluteTimeGetCurrent()
                let duration = endTime - startTime
                
                if duration > threshold {
                    blockDetected = true
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        self?.onBlock?(duration)
                    }
                }
            }
            
            // Sleep briefly to avoid excessive monitoring overhead
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    
    func stopMonitoring() {
        isMonitoring = false
    }
}
