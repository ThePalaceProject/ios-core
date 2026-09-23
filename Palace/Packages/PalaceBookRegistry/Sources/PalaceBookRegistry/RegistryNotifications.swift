//
//  RegistryNotifications.swift
//  PalaceBookRegistry
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Registry lifecycle notification names, relocated into the package (god-class
/// decomposition Wave 2b) because the engine POSTS them — the facade's
/// `BoolWithDelay` posts `TPPSyncBegan`/`TPPSyncEnded`, `postSyncFailure` posts
/// `TPPSyncFailed`, and the store/sync save posts `TPPBookRegistryDidChange`.
///
/// String values are IDENTICAL to the former app-side declarations in
/// `NSNotification+TPP.swift` — 8 app files observe `TPPBookRegistryDidChange`
/// and 5 observe `TPPSyncBegan`/`TPPSyncEnded`; those names must not change.
public extension Notification.Name {
    static let TPPSyncBegan = Notification.Name("TPPSyncBegan")
    static let TPPSyncEnded = Notification.Name("TPPSyncEnded")
    static let TPPSyncFailed = Notification.Name("TPPSyncFailed")
    static let TPPBookRegistryDidChange = Notification.Name("TPPBookRegistryDidChange")
}

extension Notification.Name {
    /// The book-processing-changed notification the store posts from `setProcessing`.
    /// Package-INTERNAL Swift symbol with the SAME runtime string as the app-side
    /// `.TPPBookProcessingDidChange` (declared in `NSNotification+TPP.swift`, which
    /// its observers still use) — kept distinct so the two module-level declarations
    /// don't collide into a cross-module ambiguity. Runtime behavior is identical.
    static let registryBookProcessingDidChange = Notification.Name("TPPBookProcessingDidChange")
}

/// The `userInfo` keys the store attaches to `registryBookProcessingDidChange`,
/// string-identical to the app-side `TPPNotificationKeys` constants.
enum RegistryProcessingNotificationKeys {
    static let bookID = "identifier"
    static let value = "value"
}
