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
        VStack(alignment: .leading, spacing: BotUI.Spacing.medium) {
            statusBadge

            Text(entry.userFacingWorkaround)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            // Primary action — full width, can't be misread. Either the
            // guided-flow entry point (preferred when steps exist) or the
            // "file a ticket" path (when there's nothing to walk through).
            if hasGuidedSteps {
                BotUI.PrimaryButton(
                    title: "Walk me through it",
                    systemImage: "list.bullet.rectangle"
                ) { onAction(.walkMeThroughIt) }
            } else {
                BotUI.PrimaryButton(
                    title: "File a ticket",
                    systemImage: "envelope.fill"
                ) { onAction(.fileAnyway) }
            }

            // Secondary actions row. Single line, tight chips. Only shown
            // when there ARE secondary actions to take.
            HStack(spacing: BotUI.Spacing.small) {
                if KBMatchActionPolicy.showsNotifyMeOnFix(
                    entryHasFixVersion: entry.fixedInVersion != nil
                ) {
                    BotUI.SecondaryChip(title: "Notify me", systemImage: "bell.fill") {
                        onAction(.notifyMe)
                    }
                }
                if hasGuidedSteps {
                    // When guided flow is the primary, file-ticket becomes
                    // a secondary "skip the steps" affordance.
                    BotUI.SecondaryChip(title: "Just file a ticket", systemImage: "envelope") {
                        onAction(.fileAnyway)
                    }
                }
            }

            Button("Thanks, I'm good") {
                onAction(.dismiss)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(BotUI.Spacing.cardPadding)
        .background(BotUI.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: BotUI.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Known issue match: \(entry.id)")
    }

    @ViewBuilder private var statusBadge: some View {
        let (label, symbol, color): (String, String, Color) = {
            switch entry.status {
            case .fixedIn:
                return ("Fixed in \(entry.fixedInVersion ?? "next release")", "checkmark.seal.fill", .green)
            case .open:
                if let version = entry.fixedInVersion {
                    return ("Known issue — fix coming in \(version)", "wrench.and.screwdriver.fill", .orange)
                }
                return ("Known issue — workaround available", "exclamationmark.triangle.fill", .orange)
            case .userError: return ("Likely a setup mix-up", "info.circle.fill", .blue)
            case .wontfix: return ("By design", "info.circle", .gray)
            case .duplicateOf: return ("Tracked", "tag.fill", .gray)
            case .none:
                // how_to (general-help) entries have no known-issue status —
                // render a neutral "how to" badge, not a bug status.
                return ("How to", "questionmark.circle.fill", .blue)
            }
        }()
        Label {
            Text(label)
                .font(.caption.weight(.semibold))
        } icon: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .lineLimit(2)
    }
}
#endif
