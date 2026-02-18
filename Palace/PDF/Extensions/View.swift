//
//  View+readSize.swift
//  Palace
//
//  Created by Vladimir Fedorov on 23.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

struct SizePreferenceKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {}
}

extension View {
  /// Returns size of a view
  ///
  /// Usage:
  /// ```
  /// view
  ///   .readSize { size in
  ///     // size - CGSize of the view
  ///   }
  func readSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
    background(
      GeometryReader { geometryProxy in
        Color.clear
          .preference(key: SizePreferenceKey.self, value: geometryProxy.size)
      }
    )
    .onPreferenceChange(SizePreferenceKey.self, perform: onChange)
  }

  /// Shows the view when `when` condition is `true`
  /// - Parameter when: Condition when the view is visible
  func visible(when: Bool) -> some View {
    opacity(when ? 1 : 0)
  }
  
  /// Minimal size for toolbar buttons
  func toolbarButtonSize() -> some View {
    frame(minWidth: 24, minHeight: 24)
  }
}

extension View {
  /// A convenience method for applying `TouchDownUpEventModifier.`
  func onTouchDownUp(pressed: @escaping ((Bool, DragGesture.Value) -> Void)) -> some View {
    self.modifier(TouchDownUpEventModifier(pressed: pressed))
  }
}

struct TouchDownUpEventModifier: ViewModifier {
  /// Keep track of the current dragging state. To avoid using `onChange`, we won't use `GestureState`
  @State var dragged = false
  
  /// A closure to call when the dragging state changes.
  var pressed: (Bool, DragGesture.Value) -> Void
  
  func body(content: Content) -> some View {
    content
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            pressed(true, value)
          }
          .onEnded { value in
            pressed(false, value)
          }
      )
  }
}
