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

    var body: some View {
        // `Color.clear` is the sizing element because it accepts whatever height
        // the stack offers, so `aspectRatio(1, .fit)` resolves to a real square
        // and the cover shrinks on a short screen instead of overflowing.
        // Applying the ratio to the artwork instead measures the artwork: a
        // `.fill` image reports its own ratio back out through the square
        // constraint, so a 2:3 cover laid out 320x480 in a 320pt slot and put
        // the portrait column 114pt over an iPhone 17 Pro screen.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { artwork }
            .clipped()
    }

    @ViewBuilder
    private var artwork: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
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
