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

    // Same dark-mode failure mode as F-003 (TicketPreviewCard Send button):
    // relying on `.accentColor` can render white-on-white depending on the
    // host app's accent definition + iOS appearance. Use a guaranteed-distinct
    // semantic color (`.systemBlue`, the iMessage convention) for user
    // bubbles so the text always reads against the background, regardless
    // of theme. Bot bubbles use the standard secondary surface, which is
    // already appearance-safe.
    private var background: Color {
        sender == .user ? Color(.systemBlue) : Color(.secondarySystemBackground)
    }

    private var foreground: Color {
        sender == .user ? Color.white : Color(.label)
    }
}
#endif
