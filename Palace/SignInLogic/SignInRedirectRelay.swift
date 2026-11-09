//
//  SignInRedirectRelay.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Carries the universal-link redirect that ends a browser sign-in (Clever
/// and other OAuth intermediaries) from the app delegate to the sign-in that
/// opened the browser.
///
/// `@unchecked Sendable`: the only state is the `let` subject, and it sends
/// only from `deliver`, which runs on the main actor.
final class SignInRedirectRelay: @unchecked Sendable {
    /// Each redirect the app receives, on the main actor.
    var redirects: AnyPublisher<URL, Never> {
        subject.eraseToAnyPublisher()
    }

    private let subject = PassthroughSubject<URL, Never>()

    @MainActor
    func deliver(_ url: URL) {
        subject.send(url)
    }
}
