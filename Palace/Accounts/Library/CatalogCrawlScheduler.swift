//
//  CatalogCrawlScheduler.swift
//  Palace
//
//  Owned-task infrastructure for AccountsManager's background catalog-crawl
//  work (PP-4754 root-cause de-flake). Splits two collaborators out of the
//  AccountsManager god class:
//
//   - `CrawlTaskScheduler`: the injectable spawn seam. Production spawns real
//     structured/detached Tasks; tests inject a recording scheduler to pin the
//     scheduling contract (site order + priority + detachedness) that a refactor
//     could otherwise silently drift.
//   - `OwnedCrawlTaskRegistry`: a self-pruning registry that gives every
//     background crawl Task a real owner. ALWAYS populated (production included)
//     so the test-boundary drain is COMPLETE — no fire-and-forget write channel
//     survives a test to pollute the next one (the systemic flake class this
//     change closes). Bounded because each task removes its own token on
//     completion.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Injectable spawn seam for AccountsManager's background catalog-crawl Tasks.
///
/// Two arms preserve each call site's exact detached-vs-inheriting semantics and
/// priority: the init / first-run / slim-refresh sites spawn `detached` at
/// `.utility`; the `fetchFromNetwork` crawl spawns an inheriting `Task` at
/// `.userInitiated`; pagination / refresh / preload spawn inheriting `Task`s at
/// `.utility`. `production` is the live implementation; a test can substitute a
/// recording scheduler that captures `(priority, detached)` per spawn to assert
/// the cold-launch scheduling contract.
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
/// `defer { registry.complete(token) }`). The registry is populated in
/// production too — this is the ownership change at the heart of PP-4754: a
/// crawl that used to be fire-and-forget now has an owner that
/// `cancelBackgroundWork()` can cancel and `cancelAndDrainBackgroundWork()` can
/// await. Growth is bounded because each task prunes its own token, so the live
/// set only ever holds genuinely in-flight work.
///
/// `@unchecked Sendable` invariant: the only mutable state (`tasks`,
/// `completedBeforeInsert`) is read and written exclusively under `lock` (an
/// immutable `NSLock`); the wrapped `Task<Void, Never>` handles are themselves
/// `Sendable`.
///
/// Insert-vs-complete race: a spawned Task can finish — and run its
/// `complete(_:)` defer — BEFORE the spawning code calls `register(_:_:)` (the
/// task is created, then registered). A naive registry would then insert a
/// handle for an already-finished task and never prune it. The `completedBeforeInsert`
/// tombstone set closes this: if `complete` runs first it records the token as a
/// tombstone; `register` then sees the tombstone, clears it, and skips the
/// insert. Even if this guard were absent the leak would be benign for the join
/// (awaiting a finished task returns immediately) — the tombstone only bounds
/// memory, which is why it is safe and cheap.
final class OwnedCrawlTaskRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var completedBeforeInsert: Set<UUID> = []

  /// Register a freshly-spawned task under `token`. Called AFTER the task is
  /// created, so it must reconcile with a `complete(_:)` that may already have
  /// run (see the tombstone rationale on the type).
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
