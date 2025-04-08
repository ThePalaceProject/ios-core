import SwiftUI

struct AdaptiveShadowModifier: ViewModifier {
  @Environment(\.colorScheme) var colorScheme
  var radius: CGFloat

  func body(content: Content) -> some View {
    content
      .shadow(color: Color.white.opacity(0.3), radius: radius, x: -2, y: -2)
      .shadow(color: Color.black.opacity(0.6), radius: radius, x: 2, y: 2)
  }
}

extension View {
  func adaptiveShadow(radius: CGFloat = 10) -> some View {
    self.modifier(AdaptiveShadowModifier(radius: radius))
  }
}
