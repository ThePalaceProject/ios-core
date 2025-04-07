import SwiftUI

struct AdaptiveShadowModifier: ViewModifier {
  @Environment(\.colorScheme) var colorScheme

  func body(content: Content) -> some View {
    content
      .shadow(color: Color.white.opacity(0.3), radius: 5, x: -2, y: -2)
      .shadow(color: Color.black.opacity(0.6), radius: 5, x: 2, y: 2)
  }
}

extension View {
  func adaptiveShadow() -> some View {
    self.modifier(AdaptiveShadowModifier())
  }
}
