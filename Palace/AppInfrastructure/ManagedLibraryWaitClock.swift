//
//  ManagedLibraryWaitClock.swift
//  Palace
//
//  How long have we been waiting for THIS configuration?
//
//  ## The bug this exists to remove
//
//  The bounded wait for the registry was measured from the first time the app
//  asked, once per launch, and never restarted. That is the right answer only
//  while the configuration does not change.
//
//  It can. An administrator moving a device between division groups pushes a
//  new value, and an MDM can push one while the app is starting — which is
//  exactly the morning-on-a-school-network case the wait exists for. When that
//  happened, the new configuration inherited the old one's elapsed time. If the
//  first had been sitting there for sixteen seconds, the second got no grace
//  period at all: it fell straight through to the picker, on its very first
//  attempt, having never once been given the chance to resolve.
//
//  The wait belongs to the configuration, not to the launch. Keying it to the
//  configuration's identity is what makes that true, and it makes the old
//  behaviour unrepresentable rather than merely fixed.
//
//  ## Why this is a type rather than two lines in the app delegate
//
//  It was two lines in the app delegate, and the defect above lived in them
//  unseen because nothing there is reachable from a test. `now` is a parameter
//  for the same reason: a clock you cannot advance is a clock you cannot
//  assert on.
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
