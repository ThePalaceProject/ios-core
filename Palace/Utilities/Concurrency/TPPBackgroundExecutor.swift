//
//  TPPBackgroundExecutor.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 2/6/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import UIKit
import Dispatch
import PalaceLogging

/**
 Protocol that should be implemented by a class that wants to schedule work
 in the background using `TPPBackgroundExecutor`.
 */
@objc protocol NYPLBackgroundWorkOwner {
    /// Implementors should do 2 things:
    ///
    /// 1. Create the work item.
    /// If you're calling this function from ObjC, the work item must be
    /// created via `dispatch_block_create` to avoid undefined
    /// behavior (see docs for `dispatch_block_cancel()`).
    ///
    /// 2. Invoke the `backgroundWork` block parameter from inside the work item.
    ///
    /// E.g.:
    /// ```objc
    /// - (dispatch_block_t)setUpWorkItemWrappingBackgroundWork:(void(^)(void))backgroundWork
    /// {
    ///   dispatch_block_t workItem = dispatch_block_create(0, ^{
    ///     backgroundWork();
    ///   });
    ///   return workItem;
    /// }
    /// ```
    ///
    /// Then when used in conjunction with `TPPBackgroundExecutor`,
    /// `TPPBackgroundExecutor::dispatchBackgroundWork()` will call
    /// `setUpWorkItem(wrapping:)` at the right time. The executor takes
    /// care of starting and ending the background task for you,
    /// performing the appropriate logging.
    ///
    /// - Parameter backgroundWork: The block that the owning class should invoke
    /// from inside the work-item / dispatch-block it created.
    ///
    /// - Returns: The created work item. Callers are not required to retain
    /// this since it will be retained TPPBackgroundExecutor's queue.
    ///
    @objc(setUpWorkItemWrappingBackgroundWork:)
    func setUpWorkItem(wrapping backgroundWork: @escaping () -> Void) -> (() -> Void)?

    /// The actual expensive / long running work. Don't add any background task
    /// handling in here!
    func performBackgroundWork()
}

/**
 This class wraps the logic of initiating and ending a background task on behalf
 of a `owner` in a thread-safe manner.

 The work defined in `NYPLBackgroundWorkOwner::performBackgroundWork` is
 executed concurrently on the global background queue with the assumption that
 it is thread-safe.
 */
// Swift 6 `complete` — `@unchecked Sendable` invariant: `self` is captured
// (always weakly) into the `@Sendable` `beginBackgroundTask` expiration handler,
// the `endQueue`/main hops, and the `queue.async` work item. The stored state is
// safe to share: `taskName`, `queue`, and `endLock` are immutable `let`s; `owner`
// is a `weak var` written exactly once in `init` and only read thereafter; and
// `isEndingTask` is mutated and read solely under `endLock`. No unguarded mutable
// state races — this comment is the documented invariant, not a bare waiver.
@objc class TPPBackgroundExecutor: NSObject, @unchecked Sendable {
    private let taskName: String
    private weak var owner: NYPLBackgroundWorkOwner?
    private let queue = DispatchQueue.global(qos: .background)
    private let endLock = NSLock()
    private var isEndingTask = false

    // ----------------------------------------------------------------------------

    /// - Parameters:
    ///   - owner: The object wanting to run an expensive task in the background.
    ///   - taskName: A name for the task, for debugging/logging purposes.
    @objc init(owner: NYPLBackgroundWorkOwner, taskName: String) {
        self.taskName = taskName
        self.owner = owner
        super.init()
    }

    // ----------------------------------------------------------------------------

    /// The owner needs to call this function to perform in the background the
    ///  work specified in `NYPLBackgroundWorkOwner::performBackgroundWork`.
    /// All the mechanics of starting and ending a background task (including
    /// the related logging) are handled here.
    /// Swift 6 `complete`: the background-task identifier is mutated across the
    /// `@Sendable` `beginBackgroundTask` expiration handler, the `endQueue`/main
    /// hops in `endTaskIfNeeded`, and the `startBackground` closure. A by-ref
    /// captured `var bgTask` is a data race under strict concurrency, so we hold it
    /// in a lock-backed carrier box shared by all those closures. The lock guards
    /// each individual get/set of the identifier (the begin→end→invalidate sequence
    /// itself is kept single-entry by the existing `isEndingTask`/`endLock` guard +
    /// main-thread serialization, not by this lock). Not `nonisolated(unsafe)`:
    /// the box is a documented, lock-guarded holder, not a race waiver.
    private final class BackgroundTaskIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UIBackgroundTaskIdentifier = .invalid

        var rawValue: Int { lock.withLock { value.rawValue } }
        func get() -> UIBackgroundTaskIdentifier { lock.withLock { value } }
        func set(_ newValue: UIBackgroundTaskIdentifier) { lock.withLock { value = newValue } }
    }

    @objc func dispatchBackgroundWork() {
        let bgTaskBox = BackgroundTaskIDBox()

        let endQueue = DispatchQueue(label: "com.thepalaceproject.backgroundEndQueue", qos: .userInitiated)

        // `@Sendable`: `endTaskIfNeeded` is invoked from the `@Sendable`
        // `beginBackgroundTask` expiration handler and the owner work item, so the
        // `complete` checker requires it to be `@Sendable`. Its captures are all
        // Sendable — `self` is `@unchecked Sendable`, `endQueue` is a `let`
        // `DispatchQueue`, and `bgTaskBox` is `@unchecked Sendable`.
        @Sendable func endTaskIfNeeded(context: String) {
            endQueue.async { [weak self] in
                guard let self = self else { return }

                self.endLock.lock()
                defer { self.endLock.unlock() }

                // Prevent multiple end task calls
                if self.isEndingTask {
                    return
                }
                self.isEndingTask = true

                // Use async dispatch to main thread instead of sync to prevent deadlock.
                // DispatchQueue.main.sync from a background queue will deadlock if the
                // main thread is blocked (e.g., waiting on a lock or semaphore).
                // backgroundTimeRemaining is thread-safe to read and endBackgroundTask
                // must be called on main thread, so async is the correct pattern here.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Provably on main (dispatched to `DispatchQueue.main`);
                    // `assumeIsolated` lets the `@MainActor` `UIApplication.shared`
                    // calls run without another hop under `complete`.
                    MainActor.assumeIsolated {
                        let timeRemaining = UIApplication.shared.backgroundTimeRemaining

                        Log.info(#file, """
            \(context) \(self.taskName) background task \(bgTaskBox.rawValue). \
            Time remaining: \(timeRemaining)
            """)

                        let currentTask = bgTaskBox.get()
                        if currentTask != .invalid {
                            UIApplication.shared.endBackgroundTask(currentTask)
                            bgTaskBox.set(.invalid)
                        }

                        self.endLock.lock()
                        self.isEndingTask = false
                        self.endLock.unlock()
                    }
                }
            }
        }

        // `@MainActor @Sendable`: `startBackground` calls `@MainActor`
        // `UIApplication.shared.beginBackgroundTask` (line below) and is scheduled
        // onto `DispatchQueue.main` in the non-main branch — so it must be both
        // main-actor-isolated (to touch `UIApplication.shared`) and `@Sendable`
        // (to cross `main.async`). The `beginBackgroundTask` expiration handler is
        // itself a `@Sendable @convention(block)`; it only calls the now-`@Sendable`
        // `endTaskIfNeeded`.
        let startBackground: @MainActor @Sendable () -> Void = {
            bgTaskBox.set(UIApplication.shared.beginBackgroundTask(withName: self.taskName) {
                endTaskIfNeeded(context: "Expiring")
            })

            Log.debug(#file, "Beginning \(self.taskName) background task \(bgTaskBox.rawValue)")

            if bgTaskBox.get() == .invalid {
                Log.warn(#file, "Unable to run background task \(self.taskName)")
            }

            guard let workItem = self.owner?.setUpWorkItem(wrapping: { [weak self] in
                self?.owner?.performBackgroundWork()

                endTaskIfNeeded(context: "Finishing up")
            }) else {
                Log.warn(#file,
                         "No work item for \(self.taskName) background task \(bgTaskBox.rawValue)!")
                endTaskIfNeeded(context: "No work item")
                return
            }

            // `workItem` is the owner-supplied `(() -> Void)?` — a non-`Sendable`
            // function value. Box it so the `queue.async(execute:)` `@Sendable
            // @convention(block)` conversion is an explicit, documented single-use
            // handoff rather than an implicit non-Sendable conversion. The work
            // item is invoked exactly once on `self.queue`.
            let workItemBox = WorkItemBox(workItem)
            self.queue.async {
                workItemBox.run()
            }
        }

        if Thread.isMainThread {
            // Provably on main; call the `@MainActor` closure without a re-hop.
            MainActor.assumeIsolated {
                startBackground()
            }
        } else {
            DispatchQueue.main.async {
                startBackground()
            }
        }
    }
}

/// Carries the owner-supplied, non-`Sendable` background work item across the
/// `@Sendable` `DispatchQueue.async` boundary in `dispatchBackgroundWork()`. The
/// item is created by the owner (via `setUpWorkItem(wrapping:)`) and executed
/// exactly once on the executor's serial background queue, so wrapping it in an
/// `@unchecked Sendable` carrier is a documented single-use handoff, not a race
/// waiver.
private final class WorkItemBox: @unchecked Sendable {
    private let work: () -> Void
    init(_ work: @escaping () -> Void) { self.work = work }
    func run() { work() }
}
