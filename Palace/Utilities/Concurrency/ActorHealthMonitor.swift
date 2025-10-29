//
//  ActorHealthMonitor.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Monitors actor health and detects potential deadlocks or performance issues
/// Usage: Wrap long-running actor operations with health monitoring
/// 
/// Configuration:
/// - Enabled in DEBUG builds by default
/// - Disabled in RELEASE/production builds by default
/// - Can be toggled via Developer Settings
actor ActorHealthMonitor {
  static let shared = ActorHealthMonitor()
  
  private var activeOperations: [UUID: OperationInfo] = [:]
  private let warningThreshold: TimeInterval = 5.0  // Warn after 5s
  private let criticalThreshold: TimeInterval = 10.0  // Critical after 10s
  
  // MARK: - Configuration
  
  /// Enable/disable monitoring (configurable from settings)
  private var isEnabled: Bool {
    #if DEBUG
    // In DEBUG builds, check setting (default: enabled)
    return UserDefaults.standard.object(forKey: "TPPActorHealthMonitorEnabled") as? Bool ?? true
    #else
    // In RELEASE builds, always disabled unless explicitly enabled
    return UserDefaults.standard.object(forKey: "TPPActorHealthMonitorEnabled") as? Bool ?? false
    #endif
  }
  
  /// Set monitoring enabled state
  func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: "TPPActorHealthMonitorEnabled")
    Log.info(#file, "ActorHealthMonitor \(enabled ? "enabled" : "disabled")")
  }
  
  /// Get current enabled state
  func getEnabled() -> Bool {
    return isEnabled
  }
  
  private struct OperationInfo {
    let id: UUID
    let name: String
    let startTime: Date
    let actorType: String
    
    var duration: TimeInterval {
      return Date().timeIntervalSince(startTime)
    }
  }
  
  // MARK: - Operation Tracking
  
  /// Start monitoring an actor operation
  func startOperation(name: String, actorType: String) -> UUID {
    let id = UUID()
    
    // Skip if disabled (no overhead in production)
    guard isEnabled else { return id }
    
    let info = OperationInfo(
      id: id,
      name: name,
      startTime: Date(),
      actorType: actorType
    )
    activeOperations[id] = info
    
    // Schedule health check
    Task {
      try? await Task.sleep(nanoseconds: UInt64(warningThreshold * 1_000_000_000))
      await checkOperationHealth(id: id)
    }
    
    return id
  }
  
  /// Complete an operation
  func completeOperation(id: UUID) {
    // Skip if disabled
    guard isEnabled else { return }
    
    if let info = activeOperations.removeValue(forKey: id) {
      let duration = info.duration
      
      // Log slow operations
      if duration > warningThreshold {
        Log.warn(#file, "⚠️ Slow actor operation: \(info.name) in \(info.actorType) took \(String(format: "%.2f", duration))s")
      }
    }
  }
  
  // MARK: - Health Checks
  
  private func checkOperationHealth(id: UUID) {
    guard let info = activeOperations[id] else { return }
    
    let duration = info.duration
    
    if duration > criticalThreshold {
      Log.error(#file, "🚨 CRITICAL: Actor operation timeout - \(info.name) in \(info.actorType) exceeded \(criticalThreshold)s")
      
      TPPErrorLogger.logError(
        withCode: .downloadFail,
        summary: "Actor operation timeout detected",
        metadata: [
          "operation": info.name,
          "actorType": info.actorType,
          "duration": duration,
          "threshold": criticalThreshold
        ]
      )
    } else if duration > warningThreshold {
      Log.warn(#file, "⚠️ Actor operation slow: \(info.name) in \(info.actorType) exceeded \(warningThreshold)s")
    }
  }
  
  /// Get health report of all active operations
  func getHealthReport() -> [String: Any] {
    var report: [String: Any] = [:]
    report["activeOperationCount"] = activeOperations.count
    
    let slowOps = activeOperations.values.filter { $0.duration > warningThreshold }
    report["slowOperationCount"] = slowOps.count
    
    let criticalOps = activeOperations.values.filter { $0.duration > criticalThreshold }
    report["criticalOperationCount"] = criticalOps.count
    
    if !slowOps.isEmpty {
      report["slowOperations"] = slowOps.map { op in
        return [
          "name": op.name,
          "actorType": op.actorType,
          "duration": op.duration
        ]
      }
    }
    
    return report
  }
}

