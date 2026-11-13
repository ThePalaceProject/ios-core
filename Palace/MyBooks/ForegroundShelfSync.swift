//
//  ForegroundShelfSync.swift
//  Palace
//
//  PP-5360: returning to the app syncs loans and holds, so a change made on
//  another device shows up without a tab switch or pull-to-refresh.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry

/// When the last foreground or push-triggered shelf sync started.
protocol ShelfSyncTimestampStore: AnyObject {
    var lastSyncStarted: TimeInterval { get set }
}

/// Stored under the key `NotificationService` also reads, so a push-triggered
/// sync and a foreground sync within the same window do not both run.
final class UserDefaultsShelfSyncTimestampStore: ShelfSyncTimestampStore {
    static let key = "lastForegroundSyncTimestamp"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastSyncStarted: TimeInterval {
        get { defaults.double(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// Syncs the shelf when the app returns to the foreground, whether the patron
/// has holds, loans or both. Skips when a sync started within
/// `minimumInterval`; the window is measured from the last sync that ran, not
/// from the last skipped attempt. A failed sync leaves the shelf as it was and
/// is retried on a later foreground.
@MainActor
final class ForegroundShelfSync {
    private let minimumInterval: TimeInterval
    private let store: ShelfSyncTimestampStore
    private let now: () -> Date
    private let sync: () -> Void

    init(minimumInterval: TimeInterval = 30,
         store: ShelfSyncTimestampStore = UserDefaultsShelfSyncTimestampStore(),
         now: @escaping () -> Date = Date.init,
         sync: @escaping () -> Void) {
        self.minimumInterval = minimumInterval
        self.store = store
        self.now = now
        self.sync = sync
    }

    func appWillEnterForeground() {
        let current = now().timeIntervalSince1970
        guard current - store.lastSyncStarted > minimumInterval else { return }
        store.lastSyncStarted = current
        sync()
    }
}

extension ForegroundShelfSync {
    /// The sync a foreground runs: sync `registry`, then refresh the app icon
    /// badge from its holds, but only when the sync succeeded.
    static func registrySync(registry: @escaping () -> TPPBookRegistryProvider,
                             updateBadge: @escaping ([TPPBook]) -> Void) -> () -> Void {
        return {
            let resolved = registry()
            resolved.sync { errorDocument, _ in
                guard errorDocument == nil else { return }
                updateBadge(resolved.heldBooks)
            }
        }
    }
}
