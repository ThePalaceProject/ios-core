//
//  NetworkConditionAdapter.swift
//  Palace
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import Network

/// Adapts network configuration based on current connection type and quality
/// Integrates with existing Palace network infrastructure
@objc final class NetworkConditionAdapter: NSObject {
    static let shared = NetworkConditionAdapter()
    
    private let memoryManager = AdaptiveMemoryManager.shared
    private let reachability = Reachability.shared
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.palace.network-monitor", qos: .utility)
    
    @objc enum NetworkType: Int {
        case wifi
        case cellular
        case lowBandwidth
        case unknown
    }
    
    private(set) var currentNetworkType: NetworkType = .unknown
    
    override init() {
        super.init()
        startMonitoring()
    }
    
    deinit {
        monitor.cancel()
    }
    
    // MARK: - Network Monitoring
    
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateNetworkType(from: path)
        }
        monitor.start(queue: monitorQueue)
    }
    
    private func updateNetworkType(from path: NWPath) {
        let newType: NetworkType
        
        if path.usesInterfaceType(.wifi) {
            newType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            // Check if we're in low data mode or poor signal
            if path.isConstrained || path.isExpensive {
                newType = .lowBandwidth
            } else {
                newType = .cellular
            }
        } else if path.status == .satisfied {
            newType = .wifi
        } else {
            newType = .unknown
        }
        
        if newType != currentNetworkType {
            currentNetworkType = newType
            Log.info(#file, "Network type changed to: \(newType)")
            
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .networkTypeChanged,
                    object: newType
                )
            }
        }
    }
    
    // MARK: - Configuration Generation
    
    /// Generate URLSessionConfiguration optimized for current network conditions
    @objc func currentConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        
        switch currentNetworkType {
        case .cellular:
            configureCellularOptimized(config)
        case .lowBandwidth:
            configureLowBandwidthOptimized(config)
        case .wifi:
            configureWiFiOptimized(config)
        case .unknown:
            configureConservativeDefault(config)
        }
        
        return config
    }
    
    private func configureCellularOptimized(_ config: URLSessionConfiguration) {
        config.httpMaximumConnectionsPerHost = memoryManager.isLowMemoryDevice ? 1 : 2
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.allowsCellularAccess = true
        config.networkServiceType = .responsiveData
        
        // Respect cellular data settings
        if #available(iOS 13.0, *) {
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
        }
        
        Log.info(#file, "Configured for cellular network - max connections: \(config.httpMaximumConnectionsPerHost)")
    }
    
    private func configureLowBandwidthOptimized(_ config: URLSessionConfiguration) {
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.allowsCellularAccess = true
        config.networkServiceType = .background
        
        if #available(iOS 13.0, *) {
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
        }
        
        Log.info(#file, "Configured for low bandwidth network (LCP-compatible)")
    }
    
    private func configureWiFiOptimized(_ config: URLSessionConfiguration) {
        config.httpMaximumConnectionsPerHost = memoryManager.isLowMemoryDevice ? 3 : 6
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.networkServiceType = .default
        
        Log.info(#file, "Configured for WiFi network - max connections: \(config.httpMaximumConnectionsPerHost)")
    }
    
    private func configureConservativeDefault(_ config: URLSessionConfiguration) {
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.networkServiceType = .responsiveData
        
        Log.info(#file, "Using conservative default network configuration")
    }
    
    // MARK: - Bandwidth Assessment
    
    /// Estimate current bandwidth category for adaptive behavior
    @objc var estimatedBandwidthCategory: BandwidthCategory {
        switch currentNetworkType {
        case .wifi:
            return .high
        case .cellular:
            return .medium
        case .lowBandwidth:
            return .low
        case .unknown:
            return .low
        }
    }
    
    @objc enum BandwidthCategory: Int {
        case low    // < 1 Mbps
        case medium // 1-10 Mbps  
        case high   // > 10 Mbps
    }
    
    // MARK: - Download Prioritization
    
    /// Get maximum concurrent downloads for current network conditions
    @objc var maxConcurrentDownloads: Int {
        let baseMax = memoryManager.maxConcurrentDownloads
        
        switch currentNetworkType {
        case .wifi:
            return baseMax
        case .cellular:
            return min(baseMax, 2)
        case .lowBandwidth:
            return 2 // Increased from 1 to allow LCP streaming + background download
        case .unknown:
            return 1
        }
    }
    
    /// Should downloads be paused due to network conditions?
    @objc var shouldPauseDownloads: Bool {
        return !reachability.isConnected || currentNetworkType == .unknown
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let networkTypeChanged = Notification.Name("NetworkTypeChanged")
}

