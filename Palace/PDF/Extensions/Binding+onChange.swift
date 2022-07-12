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
    func onChange(_ handler: @escaping (Value) -> Void) -> Binding<Value> {
        return Binding(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue
                handler(newValue)
        })
    }
}
