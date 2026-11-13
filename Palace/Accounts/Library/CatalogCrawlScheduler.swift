//
//  CatalogCrawlScheduler.swift
//  Palace
//
//  Spawn seam for AccountsManager's background catalog crawl
//  (PP-4754). The crawl registers each Task in `OwnedTaskRegistry`, so it can be
//  cancelled and drained.
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
/// `.utility`.
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
