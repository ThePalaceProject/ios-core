//
//  IntelligentDownloadManager.swift
//  Palace
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

/// Enhances MyBooksDownloadCenter with intelligent download prioritization
/// based on network conditions and device capabilities
extension MyBooksDownloadCenter {
    
    // MARK: - Intelligent Download Management
    
    /// Limit active downloads based on current conditions
    @objc func limitActiveDownloads(max: Int) {
        downloadQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.maxConcurrentDownloads = max
            Log.info(#file, "Download limit adjusted to: \(max)")
            
            // If we're over the limit, pause some downloads
            let activeCount = self.bookIdentifierToDownloadTask.count
            if activeCount > max {
                self.pauseExcessDownloads(keepActive: max)
            }
        }
    }
    
    /// Pause all downloads temporarily (for memory pressure)
    @objc func pauseAllDownloads() {
        downloadQueue.async { [weak self] in
            guard let self = self else { return }
            
            Log.info(#file, "Pausing all downloads due to system pressure")
            
            for task in self.bookIdentifierToDownloadTask.values {
                task.suspend()
            }
        }
    }
    
    /// Resume downloads with intelligent prioritization
    @objc func resumeIntelligentDownloads() {
        let networkAdapter = NetworkConditionAdapter.shared
        let maxAllowed = networkAdapter.maxConcurrentDownloads
        
        downloadQueue.async { [weak self] in
            guard let self = self else { return }
            
            Log.info(#file, "Resuming downloads with limit: \(maxAllowed)")
            self.maxConcurrentDownloads = maxAllowed
            
            // Resume highest priority downloads first
            let sortedTasks = self.prioritizedDownloadTasks()
            for (index, task) in sortedTasks.enumerated() {
                if index < maxAllowed {
                    task.resume()
                }
            }
        }
    }
    
    private func pauseExcessDownloads(keepActive: Int) {
        let allTasks = Array(bookIdentifierToDownloadTask.values)
        let prioritized = prioritizedDownloadTasks()
        
        // Pause downloads beyond the limit
        for (index, task) in prioritized.enumerated() {
            if index >= keepActive {
                task.suspend()
                Log.info(#file, "Suspended download task due to limit")
            }
        }
    }
    
    private func prioritizedDownloadTasks() -> [URLSessionDownloadTask] {
        var taskPriorities: [(URLSessionDownloadTask, Priority)] = []
        
        for (bookId, task) in bookIdentifierToDownloadTask {
            guard let book = findBook(byIdentifier: bookId) else { continue }
            
            let priority = calculateDownloadPriority(for: book)
            taskPriorities.append((task, priority))
        }
        
        // Sort by priority (highest first)
        taskPriorities.sort { $0.1.rawValue > $1.1.rawValue }
        return taskPriorities.map { $0.0 }
    }
    
    private func calculateDownloadPriority(for book: TPPBook) -> Priority {
        // Audiobooks get higher priority than ebooks
        if book.defaultBookContentType == .audiobook {
            return .high
        }
        
        // Currently reading books get high priority
        let currentState = bookRegistry.state(for: book.identifier)
        if currentState == .downloading {
            return .high
        }
        
        // Books with recent activity get medium priority
        if hasRecentActivity(book: book) {
            return .medium
        }
        
        return .low
    }
    
    private func hasRecentActivity(book: TPPBook) -> Bool {
        // Check if book was accessed recently (within 24 hours)
        // This is a simplified check - could be enhanced with actual usage tracking
        return false
    }
    
    private func findBook(byIdentifier identifier: String) -> TPPBook? {
        return taskIdentifierToBook.values.first { $0.identifier == identifier }
    }
    
    private enum Priority: Int {
        case low = 1
        case medium = 2
        case high = 3
    }
}

// MARK: - Network-Aware Download Configuration

extension MyBooksDownloadCenter {
    
    /// Configure downloads based on current network conditions
    @objc func configureForNetworkConditions() {
        let networkAdapter = NetworkConditionAdapter.shared
        let config = networkAdapter.currentConfiguration()
        
        // Update session configuration if needed
        if session.configuration.httpMaximumConnectionsPerHost != config.httpMaximumConnectionsPerHost {
            Log.info(#file, "Updating download session for network conditions")
            recreateSessionWithConfiguration(config)
        }
        
        // Adjust concurrent download limits
        limitActiveDownloads(max: networkAdapter.maxConcurrentDownloads)
    }
    
    private func recreateSessionWithConfiguration(_ config: URLSessionConfiguration) {
        downloadQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Suspend current tasks
            let currentTasks = Array(self.bookIdentifierToDownloadTask.values)
            currentTasks.forEach { $0.suspend() }
            
            // Create new session
            self.session = URLSession(
                configuration: config,
                delegate: self,
                delegateQueue: nil
            )
            
            // Resume tasks with new session (they'll automatically use new config)
            currentTasks.forEach { $0.resume() }
        }
    }
}

// MARK: - Bandwidth-Aware Quality Selection

extension MyBooksDownloadCenter {
    
    /// Select appropriate quality based on network conditions
    func selectQualityForNetworkConditions() -> AudiobookQuality {
        let networkAdapter = NetworkConditionAdapter.shared
        
        switch networkAdapter.estimatedBandwidthCategory {
        case .high:
            return .standard
        case .medium:
            return .good
        case .low:
            return .basic
        }
    }
    
    enum AudiobookQuality {
        case basic    // Lower bitrate, smaller files
        case good     // Balanced quality/size
        case standard // Full quality
    }
}

// MARK: - Setup Network Monitoring

extension MyBooksDownloadCenter {
    
    /// Setup network condition monitoring
    @objc func setupNetworkMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(networkConditionsChanged),
            name: .networkTypeChanged,
            object: nil
        )
        
        // Initial configuration
        configureForNetworkConditions()
    }
    
    @objc private func networkConditionsChanged(_ notification: Notification) {
        guard let networkType = notification.object as? NetworkConditionAdapter.NetworkType else {
            return
        }
        
        Log.info(#file, "Network conditions changed, reconfiguring downloads")
        configureForNetworkConditions()
        
        // Pause downloads if network is poor
        let networkAdapter = NetworkConditionAdapter.shared
        if networkAdapter.shouldPauseDownloads {
            pauseAllDownloads()
        } else {
            resumeIntelligentDownloads()
        }
    }
}
