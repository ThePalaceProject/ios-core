#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct CategoryChipsView: View {
    let onTap: (KBCategory) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let categories: [(KBCategory, String, String)] = [
        (.audiobook, "🎧", "Audiobook"),
        (.reader, "📖", "Reading"),
        (.signin, "🔑", "Sign in"),
        (.download, "⬇️", "Download"),
        (.library, "📚", "Library"),
        (.other, "💬", "Other")
    ]

    var body: some View {
        // PP-4823 (chaos F-004): the fixed-width adaptive grid squeezed chip
        // labels into unreadable single-character columns at the largest
        // accessibility Dynamic Type sizes. At those sizes, stack the chips one
        // per row (full width) so labels stay legible and tappable; keep the
        // compact adaptive grid at normal sizes.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(categories, id: \.0) { category, emoji, label in
                    chip(category, emoji, label)
                }
            }
        } else {
            // Wider adaptive minimum so the grid drops to ~2 columns on phones
            // (narrower than a Max), giving each chip room to keep its label on a
            // single line — at 110pt the third column squeezed "Audiobook" /
            // "Download" into an ugly two-line wrap on anything below Max width.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(categories, id: \.0) { category, emoji, label in
                    chip(category, emoji, label)
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ category: KBCategory, _ emoji: String, _ label: String) -> some View {
        Button { onTap(category) } label: {
            HStack(spacing: 6) {
                Text(emoji)
                Text(label)
                    .font(.subheadline)
                    // Guarantee a single line in every layout: never wrap; shrink
                    // a hair only if a chip is ever too narrow (belt + suspenders
                    // for the widest labels at odd widths).
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Category: \(label)")
    }
}
#endif
