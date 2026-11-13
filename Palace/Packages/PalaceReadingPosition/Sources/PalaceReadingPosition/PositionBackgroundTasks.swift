//
//  PositionBackgroundTasks.swift
//  PalaceReadingPosition
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Begins and ends the background task that keeps a position post running
/// while the app is suspended. Injected so tests can drive expiration.
struct PositionBackgroundTasks: Sendable {
    /// Begins a background task and returns its identifier. The system may
    /// call `onExpiration` at any time, including before `begin` returns.
    let begin: @Sendable (_ onExpiration: @escaping @Sendable () -> Void) -> Int
    /// Ends the task with the identifier `begin` returned.
    let end: @Sendable (_ identifier: Int) -> Void

    init(
        begin: @escaping @Sendable (_ onExpiration: @escaping @Sendable () -> Void) -> Int,
        end: @escaping @Sendable (_ identifier: Int) -> Void
    ) {
        self.begin = begin
        self.end = end
    }

#if canImport(UIKit)
    /// `UIApplication` background tasks.
    static let application = PositionBackgroundTasks(
        begin: { onExpiration in
            UIApplication.shared.beginBackgroundTask(
                withName: "PalaceReadingPosition.post",
                expirationHandler: onExpiration
            ).rawValue
        },
        end: { rawValue in
            let identifier = UIBackgroundTaskIdentifier(rawValue: rawValue)
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
        }
    )
#else
    /// No background tasks outside UIKit.
    static let application = PositionBackgroundTasks(begin: { _ in 0 }, end: { _ in })
#endif
}
