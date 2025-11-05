//
//  SafeDictionary.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Thread-safe dictionary wrapper using Swift actors
/// Replaces: Manual synchronization with DispatchQueue or locks
/// 
/// Safety guarantees:
/// - All operations are atomic and serialized by the actor
/// - No data races possible - compile-time enforced
/// - Snapshots (values(), keys()) prevent iteration corruption
/// - Actor isolation prevents deadlocks from recursive access
actor SafeDictionary<Key: Hashable, Value> {
  private var storage: [Key: Value] = [:]
  
  /// Initialize with optional initial values
  init(_ initialValues: [Key: Value] = [:]) {
    self.storage = initialValues
  }
  
  // MARK: - Health Monitoring
  
  private var accessCount: Int = 0
  private var lastAccessTime: Date = Date()
  
  /// Get performance metrics for debugging
  func getMetrics() -> [String: Any] {
    return [
      "count": storage.count,
      "accessCount": accessCount,
      "lastAccessTime": lastAccessTime,
      "memoryFootprint": MemoryLayout.size(ofValue: storage)
    ]
  }
  
  // MARK: - Basic Operations
  
  /// Get value for key
  func get(_ key: Key) -> Value? {
    accessCount += 1
    lastAccessTime = Date()
    return storage[key]
  }
  
  /// Set value for key
  func set(_ key: Key, value: Value) {
    accessCount += 1
    lastAccessTime = Date()
    storage[key] = value
  }
  
  /// Remove value for key
  @discardableResult
  func remove(_ key: Key) -> Value? {
    return storage.removeValue(forKey: key)
  }
  
  /// Remove all values
  func removeAll() {
    storage.removeAll()
  }
  
  /// Check if key exists
  func contains(_ key: Key) -> Bool {
    return storage[key] != nil
  }
  
  /// Get all keys
  func keys() -> [Key] {
    return Array(storage.keys)
  }
  
  /// Get all values
  func values() -> [Value] {
    return Array(storage.values)
  }
  
  /// Get all key-value pairs
  func allPairs() -> [(Key, Value)] {
    return Array(storage)
  }
  
  /// Get count of items
  func count() -> Int {
    return storage.count
  }
  
  /// Check if empty
  func isEmpty() -> Bool {
    return storage.isEmpty
  }
  
  // MARK: - Batch Operations
  
  /// Update multiple values atomically
  func updateMultiple(_ updates: [Key: Value]) {
    for (key, value) in updates {
      storage[key] = value
    }
  }
  
  /// Remove multiple keys atomically
  func removeMultiple(_ keys: [Key]) {
    for key in keys {
      storage.removeValue(forKey: key)
    }
  }
  
  // MARK: - Functional Operations
  
  /// Map values while preserving keys
  func mapValues<T>(_ transform: (Value) -> T) -> [Key: T] {
    return storage.mapValues(transform)
  }
  
  /// Filter key-value pairs
  func filter(_ isIncluded: (Key, Value) -> Bool) -> [Key: Value] {
    return storage.filter(isIncluded)
  }
  
  /// Compact map values (transform and filter nil)
  func compactMapValues<T>(_ transform: (Value) -> T?) -> [Key: T] {
    return storage.compactMapValues(transform)
  }
  
  // MARK: - Subscript-like Access (Async)
  
  /// Update or retrieve value atomically with closure
  func modify(_ key: Key, with closure: (inout Value?) -> Void) {
    var value = storage[key]
    closure(&value)
    if let value = value {
      storage[key] = value
    } else {
      storage.removeValue(forKey: key)
    }
  }
  
  /// Perform atomic read-modify-write
  func updateValue(_ key: Key, default defaultValue: Value, with transform: (inout Value) -> Void) {
    var value = storage[key] ?? defaultValue
    transform(&value)
    storage[key] = value
  }
}

// MARK: - Dictionary-like Initialization

extension SafeDictionary: ExpressibleByDictionaryLiteral {
  init(dictionaryLiteral elements: (Key, Value)...) {
    var dict: [Key: Value] = [:]
    for (key, value) in elements {
      dict[key] = value
    }
    self.init(dict)
  }
}

// MARK: - Debugging Support

extension SafeDictionary: CustomStringConvertible {
  nonisolated var description: String {
    return "SafeDictionary<\(Key.self), \(Value.self)>"
  }
}

extension SafeDictionary: CustomDebugStringConvertible {
  nonisolated var debugDescription: String {
    return "SafeDictionary<\(Key.self), \(Value.self)> (actor-isolated)"
  }
}

