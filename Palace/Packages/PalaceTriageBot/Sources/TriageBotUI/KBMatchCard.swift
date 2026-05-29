#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct KBMatchCard: View {
    enum Action {
        case notifyMe
        case fileAnyway
        case dismiss
        /// User opted into the multi-step troubleshooting flow. Only
        /// dispatched when the entry has `userFacingSteps` populated.
        case walkMeThroughIt
    }

    let entry: KBEntry
    let onAction: (Action) -> Void

    private var hasGuidedSteps: Bool {
        (entry.userFacingSteps?.isEmpty == false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusBadge

            Text(entry.userFacingWorkaround)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            // Primary action depends on whether the entry has guided steps.
            // Entries WITH steps lead with "Walk me through this" — the
            // honest path that doesn't assume a single workaround text will
            // fix the user's specific situation. Notify-me + file-ticket
            // remain available as secondary actions.
            if hasGuidedSteps {
                actionButton("Walk me through this", systemImage: "list.bullet.rectangle") {
                    onAction(.walkMeThroughIt)
                }
            }

            HStack {
                // Offer notify-me whenever we know the planned fix version,
                // regardless of whether the bug is already shipped vs in flight.
                // "status: open with fixed_in_version: 3.2.0" is the legitimate
                // "in flight, planned for vN" state — chaos-qa F-001 caught
                // that the old UI suppressed the notify button in that case.
                if entry.fixedInVersion != nil {
                    actionButton("Notify me when fixed", systemImage: "bell.fill") {
                        onAction(.notifyMe)
                    }
                }
                actionButton("File ticket anyway", systemImage: "envelope.fill") {
                    onAction(.fileAnyway)
                }
            }

            Button("Thanks, I'm good") {
                onAction(.dismiss)
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.systemBlue).opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Known issue match: \(entry.id)")
    }

    @ViewBuilder private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch entry.status {
            case .fixedIn:
                return ("Fixed in \(entry.fixedInVersion ?? "next release")", .green)
            case .open:
                if let version = entry.fixedInVersion {
                    return ("Known issue — fix coming in \(version)", .orange)
                }
                return ("Known issue — workaround available", .orange)
            case .userError: return ("Likely a setup mix-up", .blue)
            case .wontfix: return ("By design", .gray)
            case .duplicateOf: return ("Tracked", .gray)
            }
        }()
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
    }

    @ViewBuilder private func actionButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.systemBlue).opacity(0.15))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
#endif
