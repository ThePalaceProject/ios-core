//
//  OwnedTaskRegistry.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Self-pruning registry of live `Task`s, so an owner can cancel and drain the
/// work it started without keeping handles to work that already finished.
///
/// Each Task is registered under a fresh token and removes itself on
/// completion: the spawner wraps the operation in
/// `defer { registry.complete(token) }`, in production too. Used by the
/// account catalog crawl and the EPUB reading-position poster.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
///
/// A spawned Task can finish before `register(_:_:)` runs. `complete` then
/// leaves a tombstone in `completedBeforeInsert` and `register` skips the
/// insert, so finished tasks are never left in the map.
final class OwnedTaskRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var completedBeforeInsert: Set<UUID> = []

  /// Called after the task is created, so `complete(_:)` may already have run.
  func register(_ token: UUID, _ task: Task<Void, Never>) {
    lock.lock(); defer { lock.unlock() }
    if completedBeforeInsert.remove(token) != nil {
      // The task already finished before we got here — nothing to track.
      return
    }
    tasks[token] = task
  }

  /// Self-prune: called from the spawned task's own completion `defer`.
  func complete(_ token: UUID) {
    lock.lock(); defer { lock.unlock() }
    if tasks.removeValue(forKey: token) == nil {
      // Completed before `register` inserted us — leave a tombstone so the
      // pending `register` skips the insert.
      completedBeforeInsert.insert(token)
    }
  }

  /// Request cancellation of every live task. Does not clear the map —
  /// each task's `complete(_:)` defer prunes it as it unwinds, which is what the
  /// drain then awaits.
  func cancelAll() {
    lock.lock()
    let live = Array(tasks.values)
    lock.unlock()
    for task in live { task.cancel() }
  }

  /// Snapshot of the live `(token, task)` pairs for the deterministic drain /
  /// join. Callers await OUTSIDE the lock (no lock is ever held across `await`).
  func snapshot() -> [(UUID, Task<Void, Never>)] {
    lock.lock(); defer { lock.unlock() }
    return tasks.map { ($0.key, $0.value) }
  }

  /// Count of live owned tasks — for test quiescence assertions.
  var count: Int {
    lock.lock(); defer { lock.unlock() }
    return tasks.count
  }
}
