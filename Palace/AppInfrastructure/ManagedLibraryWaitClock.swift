//
//  ManagedLibraryWaitClock.swift
//  Palace
//
//  How long have we been waiting for this configuration? The bounded registry
//  wait is keyed to the configuration's identity, not to the launch: an MDM can
//  push a new value while the app starts, and that value must get its own full
//  grace period rather than inheriting the previous one's elapsed time.
//  `now` is a parameter so tests can advance the clock.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Tracks how long the app has been waiting for a particular managed
/// configuration to become resolvable.
struct ManagedLibraryWaitClock {

    /// The configuration currently being waited on, as an opaque identity.
    private(set) var identity: String?

    /// When the wait for `identity` began.
    private(set) var startedAt: Date?

    init() {}

    /// Time spent waiting for `identity`, restarting the clock whenever the
    /// configuration changes.
    ///
    /// Returns zero on the first call for a given configuration, which is the
    /// point: a configuration that has just arrived has not been waited on at
    /// all yet, however long the app has been running.
    mutating func elapsed(for identity: String?, now: Date = Date()) -> TimeInterval {
        guard identity == self.identity, let startedAt else {
            self.identity = identity
            self.startedAt = now
            return 0
        }
        return now.timeIntervalSince(startedAt)
    }
}
