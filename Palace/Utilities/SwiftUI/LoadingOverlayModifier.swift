import SwiftUI

// MARK: - LoadingOverlayModifier

struct LoadingOverlayModifier: ViewModifier {
  var isLoading: Bool

  func body(content: Content) -> some View {
    ZStack {
      content
        .opacity(isLoading ? 0 : 1.0)

      if isLoading {
        RoundedRectangle(cornerRadius: 8)
          .fill(
            LinearGradient(
              gradient: Gradient(colors: [
                Color.gray.opacity(0.3),
                Color.gray.opacity(0.1),
                Color.gray.opacity(0.3),
              ]),
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .shimmerEffect()
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: isLoading)
  }
}

extension View {
  func loadingOverlay(isLoading: Bool) -> some View {
    modifier(LoadingOverlayModifier(isLoading: isLoading))
  }
}

// MARK: - ShimmerEffect

struct ShimmerEffect: ViewModifier {
  @State private var isAnimating = false

  func body(content: Content) -> some View {
    content
      .overlay(
        LinearGradient(
          gradient: Gradient(colors: [
            Color.gray.opacity(0.3),
            Color.gray.opacity(0.1),
            Color.gray.opacity(0.3),
          ]),
          startPoint: .leading,
          endPoint: .trailing
        )
        .mask(content)
        .animation(
          Animation.linear(duration: 1.5)
            .repeatForever(autoreverses: false)
        )
      )
      .onAppear { isAnimating = true }
  }
}

extension View {
  func shimmerEffect() -> some View {
    modifier(ShimmerEffect())
  }
}

// MARK: - ShimmerView

struct ShimmerView: View {
  var width: CGFloat
  var height: CGFloat
  var cornerRadius: CGFloat = 0

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius)
      .fill(Color.gray.opacity(0.3))
      .frame(width: width, height: height)
      .modifier(ShimmerEffect())
      .transition(.opacity)
  }
}
