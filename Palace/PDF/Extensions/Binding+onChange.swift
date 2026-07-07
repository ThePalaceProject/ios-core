//
//  Binding+onChange.swift
//  Palace
//
//  Created by Vladimir Fedorov on 23.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

extension Binding {
    /// Triggers handler(Value) when Value changes
    /// - Parameter handler: Code to run when `Value` changes
    /// - Returns: Binding with the provided handler
    ///
    /// This is a workaround for iOS versions prior to 14, where SwiftUI doesn't have `.onChange` modifier
    // `@MainActor`: SwiftUI's `Binding.init(get:set:)` closures are `@MainActor
    // @Sendable` under `complete`. Those closures capture `self` (a
    // `Binding<Value>`, which is not `Sendable`) — a capture the checker rejects
    // in a bare `@Sendable` context. Isolating `onChange` itself to the main actor
    // makes `self` a main-actor-isolated value, and a `@MainActor @Sendable`
    // closure may capture main-actor-isolated non-`Sendable` values without a data
    // race, which clears the `self`-capture and `sending 'newValue'` diagnostics on
    // the `get`/`set` bodies. Callers (`TPPPDFSearchView`, `TPPPDFNavigation`) are
    // SwiftUI `View`s already on the main actor, so this is a no-op for them.
    @MainActor
    func onChange(_ handler: @escaping @MainActor @Sendable (Value) -> Void) -> Binding<Value> {
        return Binding(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue
                handler(newValue)
            })
    }
}
