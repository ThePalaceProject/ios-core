//
//  AudiobookSessionSnapshots.swift
//  Palace
//
//  Off-main-safe mirrors of the playback session's main-actor state.
//

import Foundation
import os

/// Lock-guarded mirrors of `AudiobookSessionManager` state, readable from any
/// thread.
///
/// Remote-command handlers run on a background MediaRemote queue, and reading a
/// `@MainActor` property there trips `dispatch_assert_queue_fail` (#1199,
/// #1218). Each mirror is written on the main actor by the `didSet` of the
/// property it reflects, so the write window is a single main-actor hop and any
/// staleness is sub-frame and self-correcting.
///
/// They live here rather than on the manager because they are one concern with
/// one mechanism, and the manager is a hub under a size ceiling: a second
/// mirror added there grew it past the cap.
///
/// Static because there is a single playback session per process, which is the
/// same assumption the manager's own `static` surface already makes.
enum AudiobookSessionSnapshots {
    // MARK: - Is a manager bound

    private static let hasActiveManagerMirror =
        OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Whether an `AudiobookManager` is currently bound. Reflects the last
    /// main-actor `bind`/`stopPlayback` transition.
    static var hasActiveManager: Bool {
        hasActiveManagerMirror.withLock { $0 }
    }

    /// Written from `manager`'s `didSet`. The `Bool` is computed on the actor
    /// before it crosses into the `@Sendable` closure: referencing the
    /// `@MainActor` property from inside would not compile.
    static func setHasActiveManager(_ isActive: Bool) {
        hasActiveManagerMirror.withLock { $0 = isActive }
    }

    // MARK: - Which book is loaded

    private static let currentBookIdentifierMirror =
        OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The identifier of the book loaded for playback, or nil when none is.
    ///
    /// The archive re-download queue reads this to serve the book the patron is
    /// listening to before the rest of the shelf: that book streams every
    /// chapter from the origin until its archive lands, while the others are
    /// prefetching for an offline listen nobody is waiting on.
    static var currentBookIdentifier: String? {
        currentBookIdentifierMirror.withLock { $0 }
    }

    /// Written from the two writers of `currentBook` (open and `stopPlayback`),
    /// which `private(set)` keeps as the only ones.
    static func setCurrentBookIdentifier(_ identifier: String?) {
        currentBookIdentifierMirror.withLock { $0 = identifier }
    }
}
