import SwiftUI

// MARK: - Book Cover Shadow (Primary)

/// Multi-layered shadow that gives book covers a realistic "floating" depth.
///
/// Adapts to the *actual* surface the cover sits on, not just the system color
/// scheme. Pass the `backgroundColor` when the cover is over a custom surface
/// (e.g. the dominant-color header gradient). When omitted, the modifier falls
/// back to the system `colorScheme` to decide whether the surface is dark.
///
/// This handles all four combos:
///   • dark header color  + dark mode  (e.g. dark audiobook cover in dark mode)
///   • light header color + dark mode  (e.g. bright cover art in dark mode)
///   • dark header color  + light mode (e.g. dark thriller cover in light mode)
///   • light header color + light mode (e.g. pastel romance cover in light mode)
/// as well as the system background when no header color is present
/// (related books, catalog lanes, My Books list).
struct AdaptiveShadowModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var radius: CGFloat
    var backgroundColor: Color?

    private var onDarkSurface: Bool {
        if let bg = backgroundColor { return bg.isDark }
        return colorScheme == .dark
    }

    func body(content: Content) -> some View {
        let scale = radius / 10.0

        content
            // Highlight — overhead light reflecting off the top edge.
            // Strong on dark surfaces where black shadows vanish;
            // nearly invisible on light surfaces where it isn't needed.
            .shadow(
                color: Color.white.opacity(onDarkSurface ? 0.18 : 0.06),
                radius: 3 * scale,
                x: 0,
                y: -1 * scale
            )
            // Contact shadow — tight, right beneath the cover
            .shadow(
                color: Color.black.opacity(onDarkSurface ? 0.50 : 0.18),
                radius: 2 * scale,
                x: 0,
                y: 1 * scale
            )
            // Mid-range depth
            .shadow(
                color: Color.black.opacity(onDarkSurface ? 0.35 : 0.12),
                radius: 8 * scale,
                x: 0,
                y: 4 * scale
            )
            // Wide ambient glow
            .shadow(
                color: Color.black.opacity(onDarkSurface ? 0.25 : 0.08),
                radius: 20 * scale,
                x: 0,
                y: 8 * scale
            )
    }
}

extension View {
    /// Floating book-cover shadow. Pass the surface `backgroundColor` when the
    /// cover sits on a custom surface (header gradient, colored card, etc.).
    func adaptiveShadow(radius: CGFloat = 10, backgroundColor: Color? = nil) -> some View {
        self.modifier(AdaptiveShadowModifier(radius: radius, backgroundColor: backgroundColor))
    }
}

// MARK: - Light Shadow (List Cells)

struct AdaptiveShadowLightModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var radius: CGFloat
    var backgroundColor: Color?

    private var onDarkSurface: Bool {
        if let bg = backgroundColor { return bg.isDark }
        return colorScheme == .dark
    }

    func body(content: Content) -> some View {
        content
            .shadow(
                color: Color.black.opacity(onDarkSurface ? 0.20 : 0.08),
                radius: radius,
                x: 0,
                y: 0.5
            )
            .shadow(
                color: Color.black.opacity(onDarkSurface ? 0.10 : 0.04),
                radius: radius * 3,
                x: 0,
                y: 2
            )
    }
}

extension View {
    func adaptiveShadowLight(radius: CGFloat = 1.0, backgroundColor: Color? = nil) -> some View {
        self.modifier(AdaptiveShadowLightModifier(radius: radius, backgroundColor: backgroundColor))
    }
}
