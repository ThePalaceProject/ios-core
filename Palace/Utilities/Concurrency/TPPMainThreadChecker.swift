//
//  TPPMainThreadChecker.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 2/7/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import Dispatch

/// Carries the non-`Sendable` `work` closure across the `@Sendable`
/// `DispatchQueue.main.async` boundary in `asyncIfNeeded(_:)`. The closure is
/// invoked exactly once, on the main queue, never concurrently — so
/// `@unchecked Sendable` is sound. This box is the deliberate alternative to
/// marking `asyncIfNeeded`'s parameter `@Sendable`, which callers in Reader2 and
/// SignInLogic depend on NOT being `@Sendable` (they pass main-actor-capturing,
/// non-`Sendable` closures). Mirrors `ImageCompletionBox`.
private final class MainThreadWorkBox: @unchecked Sendable {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

@objc class TPPMainThreadRun: NSObject {

    /// Makes sure to run the specified work item synchronously on the
    /// main __thread__.
    /// - Note: If the caller was already executing on the main thread,
    /// the block is executed immediately on the same queue of the caller, which
    /// may not be the main queue.
    /// - See: https://github.com/apple/swift-corelibs-libdispatch/commit/e64e4b962e1f356d7561e7a6103b424f335d85f6
    /// - Parameters:
    ///   - work: The block to run on the main thread.
    static func sync(_ work: @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync {
                work()
            }
        }
    }

    /// Runs the specified work item on the main thread asynchrounously if we
    /// are not already on the main thread. Otherwise, the work block is run
    /// synchronously.
    /// - Note: If the caller was already executing on the main thread,
    /// the block is executed immediately on the same queue of the caller, which
    /// may not be the main queue.
    /// - See: https://github.com/apple/swift-corelibs-libdispatch/commit/e64e4b962e1f356d7561e7a6103b424f335d85f6
    /// - Parameters:
    ///   - work: The block to run on the main thread.
    @objc static func asyncIfNeeded(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            // Box the non-`Sendable` `work` so it can cross the `@Sendable`
            // `main.async` boundary; invoked once, on main, never concurrently.
            let box = MainThreadWorkBox(work)
            DispatchQueue.main.async {
                box.run()
            }
        }
    }
}
