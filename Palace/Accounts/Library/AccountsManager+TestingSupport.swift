//
//  AccountsManager+TestingSupport.swift
//  Palace
//
//  DEBUG-only test-boundary support for AccountsManager, kept out of the hub
//  (AccountsManager.swift is under the god-class LOC freeze).
//

import Foundation

#if DEBUG
extension AccountsManager {
    /// Drain + cancel background work on ALL live instances. Called at each test
    /// boundary BEFORE AccountStateStore._resetAllForTesting so any flushed late
    /// write is then wiped. Snapshot under lock (inside the holder); drain
    /// outside the lock (the drain pumps the run loop and must not hold a lock).
    ///
    /// Also retires each instance from `.TPPUseBetaDidChange`. Instances built
    /// by earlier tests can outlive their graph (each boundary rebuild leaves the
    /// previous manager alive), and every subscribed one answers a beta toggle
    /// with a global-queue `updateAccountSet` that blocks in its loader's
    /// `loadingHandlersQueue.sync`. Enough of them exhaust the dispatch worker
    /// pool, so the barriers they wait on never get a thread. A manager built
    /// after this call registers normally.
    ///
    /// Runtime-gated to XCTest as well as compiled only in DEBUG: DEBUG also
    /// covers simulator, developer and TestFlight builds, where unsubscribing
    /// the live manager would stop it following the beta toggle. Same gate as
    /// `AppContainer._resetForTesting()`, the only production-side caller.
    static func _drainAllLiveInstancesForTesting() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return
        }
        let snapshot = _liveInstancesForTesting.snapshot()
        for m in snapshot {
            NotificationCenter.default.removeObserver(m, name: .TPPUseBetaDidChange, object: nil)
            m.cancelAndDrainBackgroundWork()
        }
    }
}
#endif
