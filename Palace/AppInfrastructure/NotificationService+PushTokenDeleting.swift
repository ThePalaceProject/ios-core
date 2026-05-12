//
//  NotificationService+PushTokenDeleting.swift
//  The Palace Project
//
//  Bridges main-target `NotificationService.shared.deleteToken(for:)` (used
//  by Sign Out and Reset Account flows) to the PalaceAuth `PushTokenDeleting`
//  seam protocol so the package never reads a `.shared` singleton.
//
//  This file is NOT yet wired into `Palace.xcodeproj/project.pbxproj`.
//  Impl 4 must add it to both `Palace` and `Palace-noDRM` Sources phases.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAuth

extension NotificationService: PushTokenDeleting {
    /// Bridges the protocol seam to the existing `deleteToken(for: Account)`
    /// API. The seam takes a `TPPLibraryAccountReadable` so the package
    /// has no `Account` dependency; this extension narrows back to the
    /// concrete type via a runtime cast (the only conforming type in main
    /// target is `Account` itself — see
    /// `Account+TPPLibraryAccountReadable.swift`).
    public func deletePushToken(for libraryAccount: TPPLibraryAccountReadable) {
        guard let account = libraryAccount as? Account else { return }
        deleteToken(for: account)
    }
}
