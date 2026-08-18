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
        // The decision lives in TriageBotCore so it can be tested — this target
        // is behind `canImport(UIKit)` and macOS `swift test` never sees it.
        // Here we only map a semantic badge to its presentation.
        let (label, symbol, color): (String, String, Color) = {
            switch KBMatchBadgePolicy.badge(for: entry) {
            case .fixedIn(let version):
                return ("Fixed in \(version)", "checkmark.seal.fill", .green)
            case .knownIssueFixComing(let version):
                return ("Known issue — fix coming in \(version)", "wrench.and.screwdriver.fill", .orange)
            case .knownIssueWorkaround:
                return ("Known issue — workaround available", "exclamationmark.triangle.fill", .orange)
            case .setupMixUp: return ("Likely a setup mix-up", "info.circle.fill", .blue)
            case .byDesign: return ("By design", "info.circle", .gray)
            case .tracked: return ("Tracked", "tag.fill", .gray)
            case .howTo: return ("How to", "questionmark.circle.fill", .blue)
            case .narrowingDown:
                // A generic ladder, not an answer — must not read as one.
                // COPY PENDING PRODUCT SIGN-OFF.
                return ("Let's narrow it down", "arrow.triangle.branch", .gray)
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
