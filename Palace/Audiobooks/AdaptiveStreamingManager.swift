//
//  AdaptiveStreamingManager.swift
//  Palace
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import PalaceAudiobookToolkit

/// Manages adaptive streaming quality based on network conditions and device state
@objc final class AdaptiveStreamingManager: NSObject {
    static let shared = AdaptiveStreamingManager()
    
    private let networkAdapter = NetworkConditionAdapter.shared
    private let memoryManager = AdaptiveMemoryManager.shared
    
    override init() {
        super.init()
        setupBatteryMonitoring()
    }
    
    // MARK: - Streaming Quality Configuration
    
    @objc enum StreamingQuality: Int {
        case audioOnly64kbps = 64
        case audioOnly96kbps = 96
        case audioOnly128kbps = 128
        case standard = 256
        case adaptive = 0 // Let system decide
    }
    
    /// Configure streaming quality based on current conditions
    @objc func configureStreamingQuality() -> StreamingQuality {
        let batteryLevel = UIDevice.current.batteryLevel
        let batteryState = UIDevice.current.batteryState
        let networkType = networkAdapter.currentNetworkType
        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        
        // Critical battery mode
        if batteryState == .unplugged && batteryLevel < 0.2 {
            Log.info(#file, "Using minimal quality for critical battery")
            return .audioOnly64kbps
        }
        
        // Low power mode
        if isLowPowerMode {
            Log.info(#file, "Using reduced quality for low power mode")
            return .audioOnly96kbps
        }
        
        // Network-based quality selection
        switch networkType {
        case .lowBandwidth:
            return .audioOnly96kbps
            
        case .cellular:
            if memoryManager.isLowMemoryDevice {
                return .audioOnly128kbps
            } else {
                return .standard
            }
            
        case .wifi:
            return .standard
            
        case .unknown:
            return .audioOnly64kbps
        }
    }
    
    // MARK: - Prefetch Configuration
    
    /// Get prefetch configuration based on current conditions
    @objc func prefetchConfiguration() -> PrefetchConfiguration {
        let networkType = networkAdapter.currentNetworkType
        let batteryLevel = UIDevice.current.batteryLevel
        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        
        var config = PrefetchConfiguration()
        
        // Adjust based on network type
        switch networkType {
        case .wifi:
            config.maxPrefetchChapters = memoryManager.isLowMemoryDevice ? 3 : 5
            config.prefetchEnabled = true
            
        case .cellular:
            config.maxPrefetchChapters = 2
            config.prefetchEnabled = !isLowPowerMode
            
        case .lowBandwidth:
            config.maxPrefetchChapters = 1
            config.prefetchEnabled = false
            
        case .unknown:
            config.maxPrefetchChapters = 0
            config.prefetchEnabled = false
        }
        
        // Reduce prefetching on low battery
        if batteryLevel < 0.3 {
            config.maxPrefetchChapters = max(0, config.maxPrefetchChapters - 1)
        }
        
        if batteryLevel < 0.2 {
            config.prefetchEnabled = false
        }
        
        Log.info(#file, "Prefetch config: enabled=\(config.prefetchEnabled), maxChapters=\(config.maxPrefetchChapters)")
        return config
    }
    
    struct PrefetchConfiguration {
        var prefetchEnabled: Bool = true
        var maxPrefetchChapters: Int = 3
        var prefetchThresholdSeconds: Double = 30 // Start prefetching when 30s remain
    }
    
    // MARK: - Buffer Management
    
    /// Get buffer configuration for current conditions
    @objc func bufferConfiguration() -> BufferConfiguration {
        let networkType = networkAdapter.currentNetworkType
        let thermalState = ProcessInfo.processInfo.thermalState
        
        var config = BufferConfiguration()
        
        // Base configuration on memory capabilities
        config.initialBufferSize = memoryManager.audioBufferSize
        config.maxBufferSize = config.initialBufferSize * 4
        
        // Adjust for network conditions
        switch networkType {
        case .wifi:
            // Standard buffer sizes
            break
            
        case .cellular:
            // Slightly larger buffers for cellular to handle variability
            config.maxBufferSize = Int(Double(config.maxBufferSize) * 1.5)
            
        case .lowBandwidth:
            // Larger buffers for poor connections
            config.maxBufferSize = config.maxBufferSize * 2
            config.rebufferThreshold = 0.8 // Start rebuffering earlier
            
        case .unknown:
            // Conservative approach
            config.maxBufferSize = config.initialBufferSize * 2
        }
        
        // Reduce buffer sizes under thermal stress
        if #available(iOS 11.0, *) {
            switch thermalState {
            case .serious, .critical:
                config.maxBufferSize = config.initialBufferSize
                config.rebufferThreshold = 0.9
            default:
                break
            }
        }
        
        return config
    }
    
    struct BufferConfiguration {
        var initialBufferSize: Int = 128 * 1024 // 128KB
        var maxBufferSize: Int = 512 * 1024     // 512KB
        var rebufferThreshold: Double = 0.7     // Rebuffer when 70% consumed
    }
    
    // MARK: - Battery Monitoring
    
    private func setupBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateChanged),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryLevelChanged),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerModeChanged),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }
    
    @objc private func batteryStateChanged() {
        notifyQualityUpdateNeeded()
    }
    
    @objc private func batteryLevelChanged() {
        notifyQualityUpdateNeeded()
    }
    
    @objc private func powerModeChanged() {
        notifyQualityUpdateNeeded()
    }
    
    private func notifyQualityUpdateNeeded() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .streamingQualityUpdateNeeded,
                object: nil
            )
        }
    }
    
    // MARK: - Quality Recommendation
    
    /// Get recommended quality for specific audiobook
    @objc func recommendedQuality(for audiobook: TPPBook) -> StreamingQuality {
        let baseQuality = configureStreamingQuality()
        
        // Consider audiobook-specific factors
        if audiobook.defaultBookContentType == .audiobook {
            // For long audiobooks on cellular, prefer lower quality to save data
            if networkAdapter.currentNetworkType == .cellular {
                return .audioOnly128kbps
            }
        }
        
        return baseQuality
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let streamingQualityUpdateNeeded = Notification.Name("StreamingQualityUpdateNeeded")
}
