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
  }
}

public extension View {
  func dismissKeyboardOnTap(onDismiss: (() -> Void)? = nil) -> some View {
    modifier(DismissKeyboardOnTap(onDismiss: onDismiss))
  }
}


