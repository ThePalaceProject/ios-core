//
//  RegistryNotifications.swift
//  PalaceBookRegistry
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

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
