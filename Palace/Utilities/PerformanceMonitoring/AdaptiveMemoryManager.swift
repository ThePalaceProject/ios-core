//
//  AdaptiveMemoryManager.swift
//  Palace
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

/// Manages memory usage adaptively based on device capabilities
/// Integrates with existing Palace architecture and respects memory constraints
@objc final class AdaptiveMemoryManager: NSObject {
    static let shared = AdaptiveMemoryManager()
    
    private let deviceMemory: UInt64
    private let processInfo: ProcessInfo
    
    let isLowMemoryDevice: Bool
    
    init(processInfo: ProcessInfo = ProcessInfo.processInfo) {
        self.processInfo = processInfo
        self.deviceMemory = processInfo.physicalMemory
        self.isLowMemoryDevice = deviceMemory < 3 * 1024 * 1024 * 1024 // 3GB
        
        Log.info(#file, "AdaptiveMemoryManager initialized - Device RAM: \(deviceMemory / (1024*1024))MB, Low Memory: \(isLowMemoryDevice)")
    }
    
    // MARK: - Memory Configuration
    
    /// Audio buffer size optimized for device memory
    var audioBufferSize: Int {
        switch deviceMemory {
        case ..<(1 * 1024 * 1024 * 1024): // < 1GB
            return 32 * 1024 // 32KB
        case ..<(2 * 1024 * 1024 * 1024): // < 2GB  
            return 64 * 1024 // 64KB
        case ..<(3 * 1024 * 1024 * 1024): // < 3GB
            return 128 * 1024 // 128KB
        default:
            return 256 * 1024 // 256KB
        }
    }
    
    /// Maximum concurrent downloads based on device capability
    var maxConcurrentDownloads: Int {
        return isLowMemoryDevice ? 1 : 3
    }
    
    /// Cache memory limit optimized for device
    var cacheMemoryLimit: Int {
        switch deviceMemory {
        case ..<(1 * 1024 * 1024 * 1024): // < 1GB
            return 2 * 1024 * 1024 // 2MB
        case ..<(2 * 1024 * 1024 * 1024): // < 2GB
            return 5 * 1024 * 1024 // 5MB
        case ..<(3 * 1024 * 1024 * 1024): // < 3GB
            return 10 * 1024 * 1024 // 10MB
        default:
            return 20 * 1024 * 1024 // 20MB
        }
    }
    
    /// Maximum cache items to prevent excessive object overhead
    var maxCacheItems: Int {
        return isLowMemoryDevice ? 50 : 200
    }
    
    /// Maximum chapter count before consolidation
    var maxChapterCount: Int {
        return isLowMemoryDevice ? 100 : 500
    }
    
    // MARK: - Memory Pressure Response
    
    /// Called when memory pressure is detected
    func handleMemoryPressure(_ level: MemoryPressureLevel) {
        Log.warn(#file, "Memory pressure detected: \(level)")
        
        switch level {
        case .warning:
            clearNonEssentialCaches()
            
        case .critical:
            clearAllCaches()
            reduceOperations()
        }
    }
    
    private func clearNonEssentialCaches() {
        // Clear image cache
        ImageCache.shared.clear()
        
        // Clear general cache memory (using static method)
        // Note: GeneralCache doesn't have a static clearMemoryCache method, 
        // so we'll use the general cache clearing approach
        NotificationCenter.default.post(name: .clearGeneralCacheMemory, object: nil)
    }
    
    private func clearAllCaches() {
        clearNonEssentialCaches()
        
        // Notify all components to clear caches
        NotificationCenter.default.post(
            name: .memoryPressureCritical,
            object: nil
        )
    }
    
    private func reduceOperations() {
        // Reduce concurrent operations
        NotificationCenter.default.post(
            name: .reduceOperations,
            object: nil
        )
    }
}

// MARK: - Memory Pressure Levels

enum MemoryPressureLevel {
    case warning
    case critical
}

// MARK: - Notification Names

extension Notification.Name {
    static let memoryPressureCritical = Notification.Name("MemoryPressureCritical")
    static let reduceOperations = Notification.Name("ReduceOperations")
    static let clearGeneralCacheMemory = Notification.Name("ClearGeneralCacheMemory")
}
