#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct TicketPreviewCard: View {
    enum Action {
        case send
        case cancel
    }

    let draft: TicketDraft
    let onAction: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ticket preview")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                row("What you said", value: draft.userDescription)
                row("Category", value: draft.category.rawValue)
                row("App", value: "\(draft.context.appVersion) (\(draft.context.appBuild))")
                row("Device", value: "\(draft.context.deviceModel) · iOS \(draft.context.osVersion)")
                if let library = draft.context.libraryName {
                    row("Library", value: library)
                }
                if let network = draft.context.networkState {
                    row("Network", value: network)
                }
                if !draft.context.recentLogLines.isEmpty {
                    row("Recent logs", value: "\(draft.context.recentLogLines.count) lines · sensitive material redacted")
                }
            }

            HStack {
                Button {
                    onAction(.cancel)
                } label: {
                    Text("Cancel").padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.bordered)

                Button {
                    onAction(.send)
                } label: {
                    Text("Send").padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ticket preview — review and send")
    }

    @ViewBuilder private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TicketReceiptCard: View {
    let receipt: TicketReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sent", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundColor(.green)
            Text("Reference: \(receipt.ticketId)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Support will reply within 1 business day.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
#endif
