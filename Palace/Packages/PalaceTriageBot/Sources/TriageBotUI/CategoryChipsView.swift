#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct CategoryChipsView: View {
    let onTap: (KBCategory) -> Void

    private let categories: [(KBCategory, String, String)] = [
        (.audiobook, "🎧", "Audiobook"),
        (.reader, "📖", "Reading"),
        (.signin, "🔑", "Sign in"),
        (.download, "⬇️", "Download"),
        (.library, "📚", "Library"),
        (.other, "💬", "Other")
    ]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(categories, id: \.0) { category, emoji, label in
                Button { onTap(category) } label: {
                    HStack(spacing: 6) {
                        Text(emoji)
                        Text(label)
                            .font(.subheadline)
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
    }
}
#endif
