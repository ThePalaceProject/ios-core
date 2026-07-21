#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct TicketPreviewCard: View {
    enum Action {
        case send
        case cancel
        /// PP-4807: toggle whether an optional field is included in the ticket.
        case toggleField(TicketField)
        /// PP-4807: include/omit the log excerpt.
        case omitLogs(Bool)
        /// PP-4807: the user edited the description before sending.
        case editDescription(String)
        /// PP-4843: fired from onAppear once the preview is actually on screen.
        /// Releases the reducer's send-consent gate so a rapid Send burst can't
        /// auto-confirm a preview the patron never saw.
        case presented
    }

    let draft: TicketDraft
    let onAction: (Action) -> Void

    // Local mirror of the description so typing doesn't fight the reducer's
    // re-render; edits are pushed out via .editDescription (which redacts).
    @State private var descriptionText: String = ""
    @State private var didSeed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: BotUI.Spacing.medium) {
            HStack(spacing: BotUI.Spacing.xsmall) {
                Image(systemName: "envelope.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Ticket preview")
                    .font(.headline)
                Spacer()
            }

            // Editable description.
            VStack(alignment: .leading, spacing: 4) {
                Text("What you said")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Describe what's happening…", text: $descriptionText, axis: .vertical)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onChange(of: descriptionText) { _, newValue in
                        onAction(.editDescription(newValue))
                    }
                    .accessibilityLabel("Edit your ticket description")
            }

            VStack(alignment: .leading, spacing: 6) {
                staticRow("Category", value: draft.category.rawValue.capitalized)
                staticRow("App", value: "\(draft.context.appVersion) (\(draft.context.appBuild))")
                staticRow("Device", value: "\(draft.context.deviceModel) · iOS \(draft.context.osVersion)")

                if let library = draft.context.libraryName {
                    toggleRow("Library", value: library, field: .library)
                }
                if let network = draft.context.networkState {
                    toggleRow("Network", value: network, field: .network)
                }
                if let barcode = draft.context.libraryBarcode {
                    // Barcode is a privacy-sensitive opt-in — shown as a hash,
                    // off by default (PP-4807).
                    toggleRow("Library card", value: "\(barcode) · hashed", field: .barcode)
                }
                if let trace = draft.resolutionTrace {
                    staticRow("Steps tried", value: "\(trace.attempts.count) (\(trace.outcome.rawValue.replacingOccurrences(of: "_", with: " ")))")
                }
                if let followUp = draft.escalationFollowUp {
                    let value: String = {
                        if let answer = followUp.answer, !answer.isEmpty { return answer }
                        return "(skipped)"
                    }()
                    staticRow("Your answer", value: value)
                }
            }

            if !draft.context.recentLogLines.isEmpty {
                logExcerptSection
            }

            HStack(spacing: BotUI.Spacing.small) {
                BotUI.CancelButton(title: "Discard") { onAction(.cancel) }
                BotUI.PrimaryButton(title: "Send", systemImage: "paperplane.fill") {
                    onAction(.send)
                }
            }
        }
        .padding(BotUI.Spacing.cardPadding)
        .background(BotUI.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: BotUI.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ticket preview — review, edit, and send")
        .onAppear {
            if !didSeed {
                descriptionText = draft.userDescription
                didSeed = true
            }
            // PP-4843: acknowledge the preview is on screen — a later runloop
            // turn than the tap burst that presented it, so it releases the
            // send-consent gate only after the patron could actually see it.
            onAction(.presented)
        }
    }

    // MARK: - Log excerpt (first few already-redacted lines)

    @ViewBuilder private var logExcerptSection: some View {
        let included = !draft.omittedFields.contains(.logs)
        let excerpt = Array(draft.context.recentLogLines.prefix(3))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: BotUI.Spacing.small) {
                Text("Recent logs (\(draft.context.recentLogLines.count) lines · redacted)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: Binding(
                    get: { included },
                    set: { onAction(.omitLogs(!$0)) }
                ))
                .labelsHidden()
                .toggleStyle(BotUI.monochromeToggle)
                .accessibilityLabel("Include recent logs in the ticket")
            }
            if included {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(excerpt.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                // The excerpt slides/fades in and out with the toggle so the
                // patron sees exactly what they're adding or dropping.
                .transition(reduceMotion
                    ? .identity
                    : .opacity.combined(with: .move(edge: .top)))
            }
        }
        // Animate the show/hide off the include flag; instant under Reduce Motion.
        .animation(BotUI.Motion.gated(BotUI.Motion.fieldToggle, reduceMotion: reduceMotion),
                   value: included)
    }

    // MARK: - Rows

    @ViewBuilder private func staticRow(_ label: String, value: String) -> some View {
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

    /// A row with an include/omit toggle. Omitting drops the field from the
    /// outgoing ticket (enforced in serialization, PP-4807).
    @ViewBuilder private func toggleRow(_ label: String, value: String, field: TicketField) -> some View {
        let included = !draft.omittedFields.contains(field)
        HStack(alignment: .top, spacing: BotUI.Spacing.small) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 94, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(included ? .primary : .secondary)
                .strikethrough(!included)
                // Dim the omitted value slightly so "removed" reads at a glance,
                // on top of the strikethrough.
                .opacity(included ? 1.0 : 0.55)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                // The strike-through + dim animate in so the patron watches the
                // field leave the ticket rather than having it blink away.
                .animation(BotUI.Motion.gated(BotUI.Motion.fieldToggle, reduceMotion: reduceMotion),
                           value: included)
            Toggle("", isOn: Binding(
                get: { included },
                set: { _ in onAction(.toggleField(field)) }
            ))
            .labelsHidden()
            .toggleStyle(BotUI.monochromeToggle)
            .accessibilityLabel("Include \(label) in the ticket")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: BotUI.Spacing.small) {
            Label("Sent", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
                // A single, calm settle on the confirming seal — no bounce,
                // no repeat. Under Reduce Motion it renders at rest immediately.
                .scaleEffect(confirmed ? 1.0 : 0.85)
                .opacity(confirmed ? 1.0 : 0.0)
                .animation(BotUI.Motion.gated(BotUI.Motion.receipt, reduceMotion: reduceMotion),
                           value: confirmed)
                .onAppear {
                    // The card renders once at rest (confirmed == false), then
                    // this flips it true — the `.animation(value:)` above eases
                    // that one transition in. Under Reduce Motion it's instant.
                    confirmed = true
                }
            Text("Reference: \(receipt.ticketId)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // PP-4845: at the largest accessibility Dynamic Type this line
                // middle-truncated ("Referen…645573") so the patron couldn't
                // read their ticket reference — their only handle on the filed
                // ticket. Let it wrap like every other line on the receipt.
                .fixedSize(horizontal: false, vertical: true)
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
