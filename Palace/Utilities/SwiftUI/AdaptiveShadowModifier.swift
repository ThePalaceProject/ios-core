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

// Lightweight variant optimized for scrolling lists and large collections
struct AdaptiveShadowLightModifier: ViewModifier {
  @Environment(\.colorScheme) var colorScheme
  var radius: CGFloat
  func body(content: Content) -> some View {
    let opacity: Double = (colorScheme == .dark) ? 0.12 : 0.08
    return content
      .shadow(color: Color.black.opacity(opacity), radius: radius, x: 0, y: 0.5)
  }
}

extension View {
  func adaptiveShadowLight(radius: CGFloat = 1.0) -> some View {
    self.modifier(AdaptiveShadowLightModifier(radius: radius))
  }
}
