//
//  MyBooksDownloadQueue.swift
//  Palace
//
//  Extracted from MyBooksDownloadCenter.swift — Phase 3 decomposition.
//  Manages download queue state: active downloads, pending queue, throttling,
//  download info caching, and redirect tracking.
//
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - Download Queue Protocol

/// Protocol for download queue coordination.
/// Enables testability by allowing mock implementations in unit tests.
protocol DownloadQueueCoordinating: Actor {
  var activeCount: Int { get }
  var queueCount: Int { get }

  func canStartDownload(maxConcurrent: Int) -> Bool
  func shouldThrottleStart() async -> TimeInterval
  func registerStart(identifier: String)
  func registerCompletion(identifier: String)

  func enqueuePending(_ book: TPPBook)
  func dequeuePending(capacity: Int) -> [TPPBook]

  func cacheDownloadInfo(_ info: MyBooksDownloadInfo, for identifier: String)
  func getCachedDownloadInfo(for identifier: String) -> MyBooksDownloadInfo?
  func removeCachedDownloadInfo(for identifier: String)

  func getRedirectAttempts(for taskID: Int) -> Int
  func incrementRedirectAttempts(for taskID: Int)
  func clearRedirectAttempts(for taskID: Int)

  func reset()
}

// MARK: - Download Coordinator

/// Modern Swift actor for coordinating downloads - NO LOCKS!
///
/// Responsibilities:
/// - Tracks active download identifiers and enforces concurrency limits
/// - Manages a FIFO pending queue for downloads that exceed the concurrency cap
/// - Provides start-throttling to avoid overwhelming the server
/// - Caches download info for fast synchronous lookups
/// - Tracks redirect attempts per URLSession task to prevent infinite loops
actor DownloadCoordinator: DownloadQueueCoordinating {
  private var activeDownloadIdentifiers: Set<String> = []
  private var startTimes: [String: Date] = [:]
  private let minimumStartDelay: TimeInterval = 0.3
  private var pendingQueue: [TPPBook] = []
  private var downloadInfoCache: [String: MyBooksDownloadInfo] = [:]
  private var redirectAttempts: [Int: Int] = [:]

  var activeCount: Int {
    activeDownloadIdentifiers.count
  }

  var queueCount: Int {
    pendingQueue.count
  }

  func canStartDownload(maxConcurrent: Int) -> Bool {
    activeDownloadIdentifiers.count < maxConcurrent
  }

  func shouldThrottleStart() async -> TimeInterval {
    guard let lastStartTime = startTimes.values.max() else {
      return 0
    }

    let timeSinceLastStart = Date().timeIntervalSince(lastStartTime)
    if timeSinceLastStart < minimumStartDelay {
      return minimumStartDelay - timeSinceLastStart
    }
    return 0
  }

  func registerStart(identifier: String) {
    activeDownloadIdentifiers.insert(identifier)
    startTimes[identifier] = Date()
  }

  func registerCompletion(identifier: String) {
    activeDownloadIdentifiers.remove(identifier)
    startTimes.removeValue(forKey: identifier)
  }

  func enqueuePending(_ book: TPPBook) {
    if !pendingQueue.contains(where: { $0.identifier == book.identifier }) {
      pendingQueue.append(book)
    }
  }

  func dequeuePending(capacity: Int) -> [TPPBook] {
    guard capacity > 0, !pendingQueue.isEmpty else { return [] }

    let toStart = Array(pendingQueue.prefix(capacity))
    pendingQueue.removeFirst(min(capacity, pendingQueue.count))
    return toStart
  }

  func cacheDownloadInfo(_ info: MyBooksDownloadInfo, for identifier: String) {
    downloadInfoCache[identifier] = info
  }

  func getCachedDownloadInfo(for identifier: String) -> MyBooksDownloadInfo? {
    downloadInfoCache[identifier]
  }

  func removeCachedDownloadInfo(for identifier: String) {
    downloadInfoCache.removeValue(forKey: identifier)
  }

  func getRedirectAttempts(for taskID: Int) -> Int {
    redirectAttempts[taskID] ?? 0
  }

  func incrementRedirectAttempts(for taskID: Int) {
    redirectAttempts[taskID] = (redirectAttempts[taskID] ?? 0) + 1
  }

  func clearRedirectAttempts(for taskID: Int) {
    redirectAttempts.removeValue(forKey: taskID)
  }

  func reset() {
    activeDownloadIdentifiers.removeAll()
    startTimes.removeAll()
    pendingQueue.removeAll()
    downloadInfoCache.removeAll()
    redirectAttempts.removeAll()
  }
}
