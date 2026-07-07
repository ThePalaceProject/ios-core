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
                .foregroundStyle(foreground)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
#endif
