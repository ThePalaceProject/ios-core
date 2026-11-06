//
//  CurrentLibraryChange.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Why `AccountsManager.currentLibraryChangePublisher` emitted. Every listener
/// today reloads what it shows for the current library on both cases; the case
/// records which kind of event caused it.
enum CurrentLibraryChange: Equatable, Sendable {
    /// `AccountsManager.currentAccount` was assigned. Sent on every assignment,
    /// including re-selecting the library that is already current.
    case selected
    /// The current library stayed the same, but its catalog, authentication
    /// details or age-check result changed, or a switch flow asked listeners to
    /// reload after it started the new library's authentication document load.
    case refreshRequested
}

/// Fan-out for `CurrentLibraryChange`; see `MainThreadBroadcaster`.
typealias CurrentLibraryChangeBroadcaster = MainThreadBroadcaster<CurrentLibraryChange>

extension AccountsManager {
    /// Emits when the current library is selected or asks listeners to reload.
    var currentLibraryChangePublisher: AnyPublisher<CurrentLibraryChange, Never> {
        currentLibraryChanges.publisher
    }

    /// Tells listeners to reload what they show for the current library without
    /// selecting a library.
    func requestCurrentLibraryRefresh() {
        currentLibraryChanges.send(.refreshRequested)
    }
}
