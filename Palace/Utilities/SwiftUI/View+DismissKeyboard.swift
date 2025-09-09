import SwiftUI
import UIKit

public func dismissKeyboard() {
  UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

public struct DismissKeyboardOnTap: ViewModifier {
  public let onDismiss: (() -> Void)?

  public func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .simultaneousGesture(TapGesture().onEnded {
        dismissKeyboard()
        onDismiss?()
      })
      .simultaneousGesture(DragGesture(minimumDistance: 1).onChanged { _ in
        dismissKeyboard()
      })
  }
}

public extension View {
  func dismissKeyboardOnTap(onDismiss: (() -> Void)? = nil) -> some View {
    modifier(DismissKeyboardOnTap(onDismiss: onDismiss))
  }
}


