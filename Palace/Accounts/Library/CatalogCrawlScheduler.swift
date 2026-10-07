//
//  CatalogCrawlScheduler.swift
//  Palace
//
//  Owned-task infrastructure for AccountsManager's background catalog crawl
//  (PP-4754): an injectable spawn seam, and a registry that gives every crawl
//  Task an owner that can be cancelled and drained.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Injectable spawn seam for AccountsManager's background catalog-crawl Tasks.
///
/// Two arms preserve each call site's detached-vs-inheriting semantics; the
/// priority is the caller's. Work the first-run library picker waits on (the
/// first-run task, the first-page crawl, its direct-GET fallback) runs at
/// `.userInitiated`; the init hop, slim-snapshot write, pagination, refresh and
/// preload run at `.utility`.
struct CrawlTaskScheduler: Sendable {
  /// Spawn an inheriting `Task` at `priority`.
  var spawn: @Sendable (TaskPriority, @escaping @Sendable () async -> Void) -> Task<Void, Never>
  /// Spawn a context-free `Task.detached` at `priority`.
  var spawnDetached: @Sendable (TaskPriority, @escaping @Sendable () async -> Void) -> Task<Void, Never>

  static let production = CrawlTaskScheduler(
    spawn: { priority, operation in
      Task(priority: priority) { await operation() }
    },
    spawnDetached: { priority, operation in
      Task.detached(priority: priority) { await operation() }
    }
  )
}

/// Self-pruning owned-task registry for AccountsManager's background crawl work.
///
/// Every background Task the manager spawns is registered here under a fresh
/// token and self-removes on completion (the caller wraps the operation in a
/// `defer { registry.complete(token) }`), in production too, so
/// `cancelBackgroundWork()` can cancel and `cancelAndDrainBackgroundWork()` can
/// await every crawl.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
///
/// A spawned Task can finish before `register(_:_:)` runs. `complete` then
/// leaves a tombstone in `completedBeforeInsert` and `register` skips the
/// insert, so finished tasks are never left in the map.
final class OwnedCrawlTaskRegistry: @unchecked Sendable {
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
