#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct ChatBubble: View {
    let text: String
    let sender: ConversationMessage.Sender

    var body: some View {
        HStack {
            if sender == .user { Spacer(minLength: 40) }
            Text(text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(background)
                .foregroundColor(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(sender == .bot ? "Support bot says \(text)" : "You said \(text)")
            if sender == .bot { Spacer(minLength: 40) }
        }
    }

    private var background: Color {
        sender == .user ? Color.accentColor : Color(.secondarySystemBackground)
    }

    private var foreground: Color {
        sender == .user ? Color.white : Color(.label)
    }
}
#endif
