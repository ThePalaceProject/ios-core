import SwiftUI

struct LoadingOverlayModifier: ViewModifier {
    var isLoading: Bool

    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(isLoading ? 0 : 1.0)

            if isLoading {
                RoundedRectangle(cornerRadius: PalaceRadius.control)
                    .fill(Color.gray.opacity(0.25))
                    .shimmerEffect()
                    .transition(.opacity)
            }
        }
        .accessibleAnimation(PalaceMotion.gentle, value: isLoading)
    }
}

extension View {
    func loadingOverlay(isLoading: Bool) -> some View {
        self.modifier(LoadingOverlayModifier(isLoading: isLoading))
    }
}

/// A moving-highlight shimmer for loading skeletons. A light band sweeps across
/// the masked content, driven by an animated `phase` — the offset is a function
/// of `phase` (`PalaceMotion.shimmerOffset`), so the band actually travels.
///
/// (The previous implementation animated a `@State` bool that no visual property
/// read, so it rendered as a static grey wash.) Reduce-motion aware: when Reduce
/// Motion is on the band is parked off-screen and the content shows as a plain
/// static placeholder.
struct ShimmerEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.5),
                            Color.white.opacity(0.0)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width)
                    .offset(x: PalaceMotion.shimmerOffset(phase: phase, width: geo.size.width))
                }
                .mask(content)
                .allowsHitTesting(false)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(PalaceMotion.shimmer) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmerEffect() -> some View {
        self.modifier(ShimmerEffect())
    }
}

/// A grey placeholder rectangle that shimmers. Convenience wrapper used by
/// hand-rolled skeletons that want a single shimmering block.
struct ShimmerView: View {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.gray.opacity(0.25))
            .frame(width: width, height: height)
            .shimmerEffect()
            .transition(.opacity)
    }
}
