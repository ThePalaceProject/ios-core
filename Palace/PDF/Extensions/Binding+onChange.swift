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
    // `@MainActor @Sendable`: SwiftUI's `Binding.init(get:set:)` closures are
    // `@MainActor @Sendable` under `complete`, so the captured `handler` must match.
    // Its callers (`TPPPDFSearchView`, `TPPPDFNavigation`) pass `@MainActor` View
    // methods, so this is a no-op for them. Resolves the closure-capture warnings on
    // the `get`/`set` bodies.
    func onChange(_ handler: @escaping @MainActor @Sendable (Value) -> Void) -> Binding<Value> {
        return Binding(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue
                handler(newValue)
            })
    }
}
