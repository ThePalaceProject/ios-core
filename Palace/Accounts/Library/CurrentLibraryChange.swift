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

/// Fan-out for `CurrentLibraryChange`, delivered on the main thread.
///
/// A send from the main thread reaches every subscriber before `send` returns,
/// so a subscriber reads the state the sender set just before it (the setter's
/// new `currentAccountId`, the prior account's eviction). A send from another
/// thread is re-sent on the main queue, because most subscribers update
/// main-actor UI state.
///
/// `@unchecked Sendable`: the only stored state is the subject, and `send`
/// reaches it only on the main thread.
final class CurrentLibraryChangeBroadcaster: @unchecked Sendable {
    private let subject = PassthroughSubject<CurrentLibraryChange, Never>()

    var publisher: AnyPublisher<CurrentLibraryChange, Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ change: CurrentLibraryChange) {
        if Thread.isMainThread {
            subject.send(change)
        } else {
            DispatchQueue.main.async { [subject] in subject.send(change) }
        }
    }
}

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
