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
        VStack(alignment: .leading, spacing: BotUI.Spacing.medium) {
            HStack(spacing: BotUI.Spacing.xsmall) {
                Image(systemName: "envelope.fill")
                    .font(.headline)
                    .foregroundStyle(Color(.systemBlue))
                Text("Ticket preview")
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                row("What you said", value: draft.userDescription)
                row("Category", value: draft.category.rawValue.capitalized)
                row("App", value: "\(draft.context.appVersion) (\(draft.context.appBuild))")
                row("Device", value: "\(draft.context.deviceModel) · iOS \(draft.context.osVersion)")
                if let library = draft.context.libraryName {
                    row("Library", value: library)
                }
                if let network = draft.context.networkState {
                    row("Network", value: network)
                }
                if !draft.context.recentLogLines.isEmpty {
                    row("Recent logs", value: "\(draft.context.recentLogLines.count) lines · redacted")
                }
                if let trace = draft.resolutionTrace {
                    row("Steps tried", value: "\(trace.attempts.count) (\(trace.outcome.rawValue.replacingOccurrences(of: "_", with: " ")))")
                }
                if let followUp = draft.escalationFollowUp {
                    let value: String = {
                        if let answer = followUp.answer, !answer.isEmpty { return answer }
                        return "(skipped)"
                    }()
                    row("Your answer", value: value)
                }
            }

            HStack(spacing: BotUI.Spacing.small) {
                BotUI.CancelButton { onAction(.cancel) }
                BotUI.PrimaryButton(title: "Send", systemImage: "paperplane.fill") {
                    onAction(.send)
                }
            }
        }
        .padding(BotUI.Spacing.cardPadding)
        .background(BotUI.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: BotUI.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ticket preview — review and send")
    }

    @ViewBuilder private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: BotUI.Spacing.small) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 94, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// PP-4808: shown when a submission fails for real. Offers Retry (re-submit
/// the exact draft), Copy details (put the composed report on the clipboard so
/// the patron can email support themselves), and Start over. Never a dead end.
struct ErrorActionsCard: View {
    enum Action {
        case retry
        case copyDetails(TicketDraft)
        case startOver
    }

    let draft: TicketDraft?
    let onAction: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BotUI.Spacing.small) {
            Label("Couldn't send", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Nothing was lost — pick one:")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(spacing: BotUI.Spacing.small) {
                if let draft {
                    BotUI.PrimaryButton(title: "Try again", systemImage: "arrow.clockwise") {
                        onAction(.retry)
                    }
                    Button {
                        onAction(.copyDetails(draft))
                    } label: {
                        Label("Copy details", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Copy the ticket details to email support yourself")
                }
                Button {
                    onAction(.startOver)
                } label: {
                    Label("Start over", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(BotUI.Spacing.cardPadding)
        .background(BotUI.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: BotUI.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ticket couldn't send — retry, copy details, or start over")
    }
}

struct TicketReceiptCard: View {
    let receipt: TicketReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: BotUI.Spacing.small) {
            Label("Sent", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("Reference: \(receipt.ticketId)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Support will reply within 1 business day.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(BotUI.Spacing.cardPadding)
        .background(BotUI.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: BotUI.cardCornerRadius, style: .continuous))
    }
}
#endif
