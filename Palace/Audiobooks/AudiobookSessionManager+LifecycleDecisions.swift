//
//  AudiobookSessionManager+LifecycleDecisions.swift
//  Palace
//
//  Pure decisions the session manager takes on app-lifecycle and registry
//  events. `nonisolated static` over explicit inputs, so they are testable
//  without a live session.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel

extension AudiobookSessionManager {

    /// Pure guard for `persistActivePositionForLifecycleEvent`: only persist
    /// when there is a fully-bound active session (manager + book + model).
    /// `nonisolated static` so the decision is unit-testable without a live
    /// toolkit session (mirrors `shouldStopPlaybackOnRegistryChange` /
    /// `networkValidationError`).
    nonisolated static func shouldPersistLifecyclePosition(
        hasManager: Bool,
        hasBook: Bool,
        hasModel: Bool
    ) -> Bool {
        hasManager && hasBook && hasModel
    }

    /// Pure decision for `subscribeToBookReturn`: stop only when the book that
    /// changed is the one currently playing AND it has become `.unregistered`
    /// (returned / removed / expired). `nonisolated static` so it is unit-
    /// testable without a live session (mirrors `networkValidationError`).
    nonisolated static func shouldStopPlaybackOnRegistryChange(
        state: TPPBookState,
        changedIdentifier: String,
        currentBookIdentifier: String?
    ) -> Bool {
        state == .unregistered
            && currentBookIdentifier != nil
            && currentBookIdentifier == changedIdentifier
    }
}
