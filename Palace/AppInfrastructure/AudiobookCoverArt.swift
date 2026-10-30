//
//  AudiobookCoverArt.swift
//  Palace
//

import SwiftUI

/// The book-cover lockup shared by the full player, the downloading panel and
/// the mini bar: the artwork laid out as a square.
///
/// Separate from `AudiobookMorphingPlayerView` so its measured size can be
/// asserted directly — the portrait column budgets for a square here, and an
/// over-tall cover pushes the bottom control row off the screen.
struct AudiobookCoverArt: View {
    let image: UIImage?

    /// Blur radius as a fraction of the rendered square rather than a fixed
    /// number of points. The three call sites render this view at 320, 240 and
    /// 44pt, and a radius that suits the largest washes the smallest out: at
    /// 44pt a 2:3 cover leaves bars about 7pt wide, well inside a 24pt kernel.
    private static let blurFraction: CGFloat = 0.075

    /// Below this the bars are a few points across, where a blurred image reads
    /// as noise rather than as a backdrop. The flat dim is steadier there.
    private static let minBlurSide: CGFloat = 120

    /// Treat near-square artwork as square: it leaves no bars to fill, so the
    /// backdrop would be rendered and then completely covered.
    private static let squareTolerance: CGFloat = 0.02

    var body: some View {
        // `Color.clear` is the sizing element because it accepts whatever height
        // the stack offers, so `aspectRatio(1, .fit)` resolves to a real square
        // and the cover shrinks on a short screen instead of overflowing.
        // Applying the ratio to the artwork instead measures the artwork: a
        // `.fill` image reports its own ratio back out through the square
        // constraint, so a 2:3 cover laid out 320x480 in a 320pt slot and put
        // the portrait column 114pt over an iPhone 17 Pro screen.
        //
        // Backdrop and artwork are both overlays on that square, so neither can
        // feed a size back into it.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    backdrop(side: min(proxy.size.width, proxy.size.height))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .overlay { artwork }
            .clipped()
    }

    /// Fills the square behind artwork that is not square.
    ///
    /// The artwork is laid out `.fit`, so anything but a square cover leaves
    /// bars. Laying the artwork out `.fill` instead would cover them, but a
    /// `.fill` image overflows the square and the clip removes the overhang,
    /// which costs the top and bottom of every portrait cover (PP-5441).
    ///
    /// `opaque: true` keeps the blur from fading to transparent at its own
    /// edges, which are the square's edges — the bars are exactly the region a
    /// transparent fade would empty.
    ///
    /// Hidden from VoiceOver: the same image is already announced by `artwork`.
    @ViewBuilder
    private func backdrop(side: CGFloat) -> some View {
        if let image, !Self.isSquare(image) {
            if side >= Self.minBlurSide, !UIAccessibility.isReduceTransparencyEnabled {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: side * Self.blurFraction, opaque: true)
                    .overlay(Color.black.opacity(0.22))
                    .accessibilityHidden(true)
            } else {
                // Reduce Transparency, or a square too small for a blur to
                // read: a flat tone carries the bars without the effect.
                Color.black.opacity(0.18)
                    .accessibilityHidden(true)
            }
        }
    }

    static func isSquare(_ image: UIImage) -> Bool {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return true }
        return abs(w - h) / max(w, h) < squareTolerance
    }

    @ViewBuilder
    private var artwork: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityLabel(Strings.Generic.bookCover)
        } else {
            Image(systemName: "book.closed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .padding(8)
                .accessibilityLabel(Strings.Generic.bookCover)
        }
    }
}
