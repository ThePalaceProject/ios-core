//
//  CurrentLibraryChange.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Why `AccountsManager.currentLibraryChangePublisher` emitted. Every listener
/// today reloads what it shows for the current library on `.selected` and
/// `.refreshRequested`; the case records which kind of event caused it.
/// `.willSwitch` is sent only on `accountSwitchPublisher`.
enum CurrentLibraryChange: Equatable, Sendable {
    /// The current library is about to change from `from` to `to`. Sent
    /// before the switch cancels requests and pops navigation, and followed by
    /// `.selected`. Not sent for the first selection or a re-selection.
    case willSwitch(from: String, to: String?)
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
            .filter { change in
                if case .willSwitch = change { return false }
                return true
            }
            .eraseToAnyPublisher()
    }

    /// Every library event in the order sent, `.willSwitch` included. The
    /// container resets its per-library services from it.
    var accountSwitchPublisher: AnyPublisher<CurrentLibraryChange, Never> {
        currentLibraryChanges.publisher
    }

    /// Tells listeners to reload what they show for the current library without
    /// selecting a library.
    func requestCurrentLibraryRefresh() {
        currentLibraryChanges.send(.refreshRequested)
    }
}
