//
//  AccountsManagerEvents.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Fan-out for an accounts event, delivered on the main thread.
///
/// A send from the main thread reaches every subscriber before `send` returns,
/// so a subscriber reads the state the sender set just before it. A send from
/// another thread is re-sent on the main queue, because most subscribers update
/// main-actor UI state.
///
/// `@unchecked Sendable`: the only stored state is the subject, and `send`
/// reaches it only on the main thread.
final class MainThreadBroadcaster<Output: Sendable>: @unchecked Sendable {
    private let subject = PassthroughSubject<Output, Never>()

    var publisher: AnyPublisher<Output, Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ value: Output) {
        if Thread.isMainThread {
            subject.send(value)
        } else {
            DispatchQueue.main.async { [subject] in subject.send(value) }
        }
    }
}

/// Where a sign-in attempt is. `@objc` because `TPPLibraryAccountsProvider`,
/// which carries the report, is an Objective-C protocol.
@objc enum SignInProgress: Int, Sendable {
    /// The patron's credentials are being sent for validation.
    case started
    /// The attempt ended: signed in, failed, or abandoned.
    case finished
}

extension AccountsManager {
    /// Emits after each catalog load finishes, whether or not it parsed.
    var catalogLoadedPublisher: AnyPublisher<Void, Never> {
        catalogLoads.publisher
    }

    /// Emits each sign-in progress report, in order.
    var signInProgressPublisher: AnyPublisher<SignInProgress, Never> {
        signInProgress.publisher
    }

    func reportSignInProgress(_ progress: SignInProgress) {
        signInProgress.send(progress)
    }
}
