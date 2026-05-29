#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct ChatBubble: View {
    let text: String
    let sender: ConversationMessage.Sender

    var body: some View {
        HStack(alignment: .bottom, spacing: BotUI.Spacing.small) {
            if sender == .user { Spacer(minLength: 56) }
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundColor(foreground)
                .background(background)
                .clipShape(BubbleShape(sender: sender))
                .accessibilityLabel(sender == .bot ? "Support bot says \(text)" : "You said \(text)")
            if sender == .bot { Spacer(minLength: 56) }
        }
    }

    // Use `.systemBlue` (the iMessage convention) for user bubbles so the
    // colour is guaranteed-distinct against the page background AND the
    // `.white` foreground in all appearances. See the chaos-qa ChatBubble
    // fix earlier in this branch for the underlying rationale.
    private var background: AnyShapeStyle {
        sender == .user
            ? AnyShapeStyle(Color(.systemBlue))
            : AnyShapeStyle(Material.regularMaterial)
    }

    private var foreground: Color {
        sender == .user ? .white : Color(.label)
    }
}

/// iMessage-style asymmetric bubble — square corner on the side closest to
/// the sender (right for user, left for bot), rounded on the other three.
/// Subtle but reads as "from this side" without a tail.
private struct BubbleShape: Shape {
    let sender: ConversationMessage.Sender

    func path(in rect: CGRect) -> Path {
        let largeRadius: CGFloat = 18
        let smallRadius: CGFloat = 4
        let isUser = sender == .user
        return Path(
            roundedRect: rect,
            topLeadingRadius: largeRadius,
            bottomLeadingRadius: isUser ? largeRadius : smallRadius,
            bottomTrailingRadius: isUser ? smallRadius : largeRadius,
            topTrailingRadius: largeRadius
        )
    }
}
#endif
