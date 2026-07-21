#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct CategoryChipsView: View {
    /// PP-4844: chips are only a live affordance while the conversation is
    /// actually awaiting a category. Once the log moves on (a ticket was sent,
    /// the flow advanced), the earlier chip row is historical — tapping it is a
    /// reducer no-op. Render those inactive chips dimmed + disabled so they
    /// don't look tappable, and hide them from VoiceOver so a patron isn't
    /// promised six categories that do nothing.
    var isActive: Bool = true
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
            // narrower than a Max — at 110pt the third column wrapped "Audiobook"
            // / "Download" onto two lines. (Re-land of the pill-label fix.)
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
                    // Never wrap a chip label to a second line; shrink a hair only
                    // if a chip is ever too narrow for the label.
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
        .disabled(!isActive)
        .opacity(isActive ? 1.0 : 0.5)
        .accessibilityLabel("Category: \(label)")
        .accessibilityHidden(!isActive)
    }
}
#endif
