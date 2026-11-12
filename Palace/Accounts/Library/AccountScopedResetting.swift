//
//  AccountScopedResetting.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

/// A service that holds state for the current library and drops it when the
/// patron switches library. Its container calls `resetForAccountSwitch()` on
/// `.willSwitch`, before the switch cancels requests; list it in its storage's
/// `accountScopedServices()` (checked by `AccountScopedResetTests`). Audiobook
/// playback is not a conformer: it continues across a switch, for CarPlay.
/// Only the requirement is `@MainActor`, so a type that is not main-actor
/// isolated can conform without changing its other members.
protocol AccountScopedResetting: AnyObject {
    @MainActor func resetForAccountSwitch()
}
